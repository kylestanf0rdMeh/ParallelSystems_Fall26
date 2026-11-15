//!
//! participant.rs
//! Implementation of 2PC participant
//!
extern crate ipc_channel;
extern crate log;
extern crate rand;
extern crate stderrlog;

use participant::rand::prelude::*;
use participant::ipc_channel::ipc::IpcReceiver as Receiver;
use participant::ipc_channel::ipc::IpcSender as Sender;

use message::MessageType;
use message::ProtocolMessage;
use oplog;

///
/// ParticipantState
/// enum for Participant 2PC state machine
///
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParticipantState {
    Quiescent,
    ReceivedP1,
    VotedAbort,
    VotedCommit,
    AwaitingGlobalDecision,
}

///
/// Participant
/// Structure for maintaining per-participant state and communication/synchronization objects to/from coordinator
///
#[derive(Debug)]
pub struct Participant {
    id_str: String,
    state: ParticipantState,
    log: oplog::OpLog,
    send_success_prob: f64,
    operation_success_prob: f64,
    tx: Sender<ProtocolMessage>,
    rx: Receiver<ProtocolMessage>,
    committed: u64,
    aborted: u64,
    // Proposals voted on but with no global decision yet
    unknown: u64,
}

///
/// Participant
/// Implementation of participant for the 2PC protocol
/// Required:
/// 1. new -- Constructor
/// 2. pub fn report_status -- Reports number of committed/aborted/unknown for each participant
/// 3. pub fn protocol() -- Implements participant side protocol for 2PC
///
impl Participant {

    ///
    /// new()
    ///
    /// Return a new participant, ready to run the 2PC protocol with the coordinator.
    ///
    pub fn new(
        id_str: String,
        log_path: String,
        send_success_prob: f64,
        operation_success_prob: f64,
        tx: Sender<ProtocolMessage>,
        rx: Receiver<ProtocolMessage>) -> Participant {

        Participant {
            id_str: id_str,
            state: ParticipantState::Quiescent,
            log: oplog::OpLog::new(log_path),
            send_success_prob: send_success_prob,
            operation_success_prob: operation_success_prob,
            tx: tx,
            rx: rx,
            committed: 0,
            aborted: 0,
            unknown: 0,
        }
    }

    ///
    /// send()
    /// Send a protocol message to the coordinator. This can fail depending on
    /// the success probability. For testing purposes, make sure to not specify
    /// the -S flag so the default value of 1 is used for failproof sending.
    ///
    pub fn send(&mut self, pm: ProtocolMessage) {
        let x: f64 = random();
        if x <= self.send_success_prob {
            if self.tx.send(pm).is_err() {
                warn!("{}::Coordinator unreachable", self.id_str);
            }
        } else {
            // Simulated message loss: the coordinator will time out on us.
            debug!("{}::Dropped {:?} for {}", self.id_str, pm.mtype, pm.txid);
        }
    }

    ///
    /// perform_operation
    /// Perform the operation specified in the 2PC proposal,
    /// with some probability of success/failure determined by the
    /// command-line option success_probability.
    ///
    pub fn perform_operation(&mut self, request: &ProtocolMessage) -> bool {

        trace!("{}::Performing operation {}", self.id_str, request.txid);
        let x: f64 = random();
        x <= self.operation_success_prob
    }

    ///
    /// report_status()
    /// Report the abort/commit/unknown status (aggregate) of all transaction
    /// requests made by this coordinator before exiting.
    ///
    pub fn report_status(&mut self) {
        println!("{:16}:\tCommitted: {:6}\tAborted: {:6}\tUnknown: {:6}", self.id_str.clone(), self.committed, self.aborted, self.unknown);
    }

    ///
    /// handle_proposal()
    /// Phase 1: execute the operation, log our vote and send it.
    ///
    fn handle_proposal(&mut self, request: ProtocolMessage) {
        self.state = ParticipantState::ReceivedP1;
        let vote = if self.perform_operation(&request) {
            self.state = ParticipantState::VotedCommit;
            MessageType::ParticipantVoteCommit
        } else {
            self.state = ParticipantState::VotedAbort;
            MessageType::ParticipantVoteAbort
        };

        // log entries carry the originating client as sender, like the coordinator's
        self.log.append(vote, request.txid.clone(), request.senderid.clone(), request.opid);
        let pm = ProtocolMessage::generate(vote, request.txid, self.id_str.clone(), request.opid);
        self.send(pm);
        self.unknown += 1;
        self.state = ParticipantState::AwaitingGlobalDecision;
    }

    ///
    /// handle_decision()
    /// Phase 2: log the coordinator's decision.
    ///
    fn handle_decision(&mut self, decision: ProtocolMessage) {
        self.log.append(decision.mtype, decision.txid.clone(), decision.senderid.clone(), decision.opid);
        if decision.mtype == MessageType::CoordinatorCommit {
            self.committed += 1;
        } else {
            self.aborted += 1;
        }
        self.unknown -= 1;
        self.state = ParticipantState::Quiescent;
    }

    ///
    /// protocol()
    /// Implements the participant side of the 2PC protocol. Runs until the
    /// coordinator says to exit (it does so on completion and on Ctrl-C) or
    /// the channel to it closes.
    ///
    pub fn protocol(&mut self) {
        trace!("{}::Beginning protocol", self.id_str.clone());

        while let Ok(pm) = self.rx.recv() {
            match pm.mtype {
                MessageType::CoordinatorPropose => self.handle_proposal(pm),
                MessageType::CoordinatorCommit | MessageType::CoordinatorAbort => self.handle_decision(pm),
                MessageType::CoordinatorExit => break,
                other => warn!("{}::Unexpected {:?}", self.id_str, other),
            }
        }

        trace!("{}::Exiting", self.id_str.clone());
        self.report_status();
    }
}
