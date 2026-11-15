//!
//! coordinator.rs
//! Implementation of 2PC coordinator
//!
extern crate log;
extern crate stderrlog;
extern crate rand;
extern crate ipc_channel;

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use coordinator::ipc_channel::ipc::IpcSender as Sender;
use coordinator::ipc_channel::ipc::IpcReceiver as Receiver;

use message::MessageType;
use message::ProtocolMessage;
use oplog;

/// How long to wait for phase 1 votes before treating the missing ones as
/// aborts. With -S 1 this gave 4 false aborts in 20000 transactions
/// (20 clients, 10 participants), and every dropped vote costs this much, so
/// it is kept short.
const VOTE_TIMEOUT: Duration = Duration::from_millis(10);

/// How often to re-check the running flag while idle.
const POLL_INTERVAL: Duration = Duration::from_millis(100);

/// CoordinatorState
/// States for 2PC state machine
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CoordinatorState {
    Quiescent,
    ReceivedRequest,
    ProposalSent,
    ReceivedVotesAbort,
    ReceivedVotesCommit,
    SentGlobalDecision
}

/// Coordinator
/// Struct maintaining state for coordinator
#[derive(Debug)]
pub struct Coordinator {
    state: CoordinatorState,
    running: Arc<AtomicBool>,
    log: oplog::OpLog,
    num_requests: u32,
    participants: Vec<Sender<ProtocolMessage>>,
    clients: HashMap<String, Sender<ProtocolMessage>>,
    // Every client and participant receiver is drained by its own thread
    // into one of these, which gives us recv_timeout.
    request_tx: mpsc::Sender<ProtocolMessage>,
    request_rx: mpsc::Receiver<ProtocolMessage>,
    vote_tx: mpsc::Sender<ProtocolMessage>,
    vote_rx: mpsc::Receiver<ProtocolMessage>,
    committed: u64,
    aborted: u64,
    unknown: u64,
}

/// Forward everything from an IPC receiver into an mpsc channel until either
/// side hangs up.
fn forward(rx: Receiver<ProtocolMessage>, tx: mpsc::Sender<ProtocolMessage>) {
    thread::spawn(move || {
        while let Ok(pm) = rx.recv() {
            if tx.send(pm).is_err() {
                break;
            }
        }
    });
}

///
/// Coordinator
/// Implementation of coordinator functionality
/// Required:
/// 1. new -- Constructor
/// 2. protocol -- Implementation of coordinator side of protocol
/// 3. report_status -- Report of aggregate commit/abort/unknown stats on exit.
/// 4. participant_join -- What to do when a participant joins
/// 5. client_join -- What to do when a client joins
///
impl Coordinator {

    ///
    /// new()
    /// Initialize a new coordinator
    ///
    /// <params>
    ///     log_path: directory for log files --> create a new log there.
    ///     r: atomic bool --> still running?
    ///     num_requests: requests each client will issue
    ///
    pub fn new(
        log_path: String,
        r: &Arc<AtomicBool>,
        num_requests: u32) -> Coordinator {

        let (request_tx, request_rx) = mpsc::channel();
        let (vote_tx, vote_rx) = mpsc::channel();
        Coordinator {
            state: CoordinatorState::Quiescent,
            log: oplog::OpLog::new(log_path),
            running: r.clone(),
            num_requests: num_requests,
            participants: Vec::new(),
            clients: HashMap::new(),
            request_tx: request_tx,
            request_rx: request_rx,
            vote_tx: vote_tx,
            vote_rx: vote_rx,
            committed: 0,
            aborted: 0,
            unknown: 0,
        }
    }

    ///
    /// participant_join()
    /// Adds a new participant for the coordinator to keep track of
    ///
    pub fn participant_join(&mut self, name: &String, tx: Sender<ProtocolMessage>, rx: Receiver<ProtocolMessage>) {
        assert!(self.state == CoordinatorState::Quiescent);

        info!("coordinator::{} joined", name);
        self.participants.push(tx);
        forward(rx, self.vote_tx.clone());
    }

    ///
    /// client_join()
    /// Adds a new client for the coordinator to keep track of
    ///
    pub fn client_join(&mut self, name: &String, tx: Sender<ProtocolMessage>, rx: Receiver<ProtocolMessage>) {
        assert!(self.state == CoordinatorState::Quiescent);

        info!("coordinator::{} joined", name);
        self.clients.insert(name.clone(), tx);
        forward(rx, self.request_tx.clone());
    }

    ///
    /// report_status()
    /// Report the abort/commit/unknown status (aggregate) of all transaction
    /// requests made by this coordinator before exiting.
    ///
    pub fn report_status(&mut self) {
        println!("coordinator     :\tCommitted: {:6}\tAborted: {:6}\tUnknown: {:6}", self.committed, self.aborted, self.unknown);
    }

    ///
    /// collect_votes()
    /// Wait for a phase 1 vote from every participant on txid. Returns
    /// Some(true) if all voted commit, Some(false) on any abort vote or timeout,
    /// and None if we were interrupted before deciding.
    ///
    fn collect_votes(&mut self, txid: &String) -> Option<bool> {
        let deadline = Instant::now() + VOTE_TIMEOUT;
        let mut commits = 0;

        while commits < self.participants.len() {
            if !self.running.load(Ordering::SeqCst) {
                return None;
            }
            let now = Instant::now();
            if now >= deadline {
                debug!("coordinator::{} timed out with {} of {} votes", txid, commits, self.participants.len());
                return Some(false);
            }
            match self.vote_rx.recv_timeout(deadline - now) {
                // Late votes for a transaction we already aborted are dropped.
                Ok(ref pm) if pm.txid != *txid => trace!("coordinator::Dropping stale vote for {}", pm.txid),
                Ok(ref pm) if pm.mtype == MessageType::ParticipantVoteCommit => commits += 1,
                Ok(_) => return Some(false),
                Err(mpsc::RecvTimeoutError::Timeout) => {},
                Err(mpsc::RecvTimeoutError::Disconnected) => return Some(false),
            }
        }
        Some(true)
    }

    ///
    /// broadcast()
    /// Send a message to every participant.
    ///
    fn broadcast(&self, pm: &ProtocolMessage) {
        for p in self.participants.iter() {
            if p.send(pm.clone()).is_err() {
                warn!("coordinator::Failed to reach a participant");
            }
        }
    }

    ///
    /// handle_request()
    /// Runs both phases of 2PC for one client request. Returns false if the
    /// simulation was stopped before a decision was reached.
    ///
    fn handle_request(&mut self, request: ProtocolMessage) -> bool {
        self.state = CoordinatorState::ReceivedRequest;
        let txid = request.txid.clone();
        let client = request.senderid.clone();
        info!("coordinator::Received {}", txid);

        // Phase 1
        let propose = ProtocolMessage::generate(MessageType::CoordinatorPropose,
                                                txid.clone(), client.clone(), request.opid);
        self.broadcast(&propose);
        self.state = CoordinatorState::ProposalSent;

        let commit = match self.collect_votes(&txid) {
            Some(c) => c,
            None => {
                self.unknown += 1;
                return false;
            }
        };

        // Phase 2
        let (decision, result) = if commit {
            self.state = CoordinatorState::ReceivedVotesCommit;
            self.committed += 1;
            (MessageType::CoordinatorCommit, MessageType::ClientResultCommit)
        } else {
            self.state = CoordinatorState::ReceivedVotesAbort;
            self.aborted += 1;
            (MessageType::CoordinatorAbort, MessageType::ClientResultAbort)
        };
        self.log.append(decision, txid.clone(), client.clone(), request.opid);
        self.broadcast(&ProtocolMessage::generate(decision, txid.clone(), client.clone(), request.opid));
        self.state = CoordinatorState::SentGlobalDecision;

        let reply = ProtocolMessage::generate(result, txid, client.clone(), request.opid);
        if self.clients[&client].send(reply).is_err() {
            warn!("coordinator::Failed to reach {}", client);
        }
        self.state = CoordinatorState::Quiescent;
        true
    }

    ///
    /// protocol()
    /// Implements the coordinator side of the 2PC protocol. Handles one
    /// transaction at a time until every client request has been decided or
    /// the simulation is interrupted, then tells everyone to exit.
    ///
    pub fn protocol(&mut self) {
        let total = self.clients.len() as u64 * self.num_requests as u64;

        while self.running.load(Ordering::SeqCst) && self.committed + self.aborted < total {
            match self.request_rx.recv_timeout(POLL_INTERVAL) {
                Ok(request) => {
                    if !self.handle_request(request) {
                        break;
                    }
                },
                Err(mpsc::RecvTimeoutError::Timeout) => {},
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }

        let exit = ProtocolMessage::generate(MessageType::CoordinatorExit,
                                             String::new(), "coordinator".to_string(), 0);
        self.broadcast(&exit);
        for c in self.clients.values() {
            let _ = c.send(exit.clone());
        }

        self.report_status();
    }
}
