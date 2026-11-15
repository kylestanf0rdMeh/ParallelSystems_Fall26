//!
//! client.rs
//! Implementation of 2PC client
//!
extern crate ipc_channel;
extern crate log;
extern crate stderrlog;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use client::ipc_channel::ipc::IpcReceiver as Receiver;
use client::ipc_channel::ipc::IpcSender as Sender;

use message;
use message::MessageType;

// Client state and primitives for communicating with the coordinator
#[derive(Debug)]
pub struct Client {
    pub id_str: String,
    pub running: Arc<AtomicBool>,
    pub num_requests: u32,
    tx: Sender<message::ProtocolMessage>,
    rx: Receiver<message::ProtocolMessage>,
    committed: u64,
    aborted: u64,
    // Set once the coordinator has told us to exit (or has gone away)
    done: bool,
}

///
/// Client Implementation
/// Required:
/// 1. new -- constructor
/// 2. pub fn report_status -- Reports number of committed/aborted/unknown
/// 3. pub fn protocol(&mut self, n_requests: i32) -- Implements client side protocol
///
impl Client {

    ///
    /// new()
    ///
    /// Constructs and returns a new client, ready to run the 2PC protocol
    /// with the coordinator.
    ///
    pub fn new(id_str: String,
               running: Arc<AtomicBool>,
               tx: Sender<message::ProtocolMessage>,
               rx: Receiver<message::ProtocolMessage>) -> Client {
        Client {
            id_str: id_str,
            running: running,
            num_requests: 0,
            tx: tx,
            rx: rx,
            committed: 0,
            aborted: 0,
            done: false,
        }
    }

    ///
    /// wait_for_exit_signal(&mut self)
    /// Wait until the coordinator tells us the simulation is over
    ///
    pub fn wait_for_exit_signal(&mut self) {
        trace!("{}::Waiting for exit signal", self.id_str.clone());

        while !self.done {
            match self.rx.recv() {
                Ok(ref pm) if pm.mtype != MessageType::CoordinatorExit => {},
                _ => self.done = true,
            }
        }

        trace!("{}::Exiting", self.id_str.clone());
    }

    ///
    /// send_next_operation(&mut self)
    /// Send the next operation to the coordinator
    ///
    pub fn send_next_operation(&mut self) {

        // Create a new request with a unique TXID.
        self.num_requests = self.num_requests + 1;
        let txid = format!("{}_op_{}", self.id_str.clone(), self.num_requests);
        let pm = message::ProtocolMessage::generate(message::MessageType::ClientRequest,
                                                    txid.clone(),
                                                    self.id_str.clone(),
                                                    self.num_requests);
        info!("{}::Sending operation #{}", self.id_str.clone(), self.num_requests);

        if self.tx.send(pm).is_err() {
            self.done = true;
        }

        trace!("{}::Sent operation #{}", self.id_str.clone(), self.num_requests);
    }

    ///
    /// recv_result()
    /// Wait for the coordinator to respond with the result for the
    /// last issued request. Note that we assume the coordinator does
    /// not fail in this simulation
    ///
    pub fn recv_result(&mut self) {

        info!("{}::Receiving Coordinator Result", self.id_str.clone());

        match self.rx.recv() {
            Ok(ref pm) if pm.mtype == MessageType::ClientResultCommit => self.committed += 1,
            Ok(ref pm) if pm.mtype == MessageType::ClientResultAbort => self.aborted += 1,
            // CoordinatorExit, or the coordinator is gone: this request stays unknown
            _ => self.done = true,
        }
    }

    ///
    /// report_status()
    /// Report the abort/commit/unknown status (aggregate) of all transaction
    /// requests made by this client before exiting.
    ///
    pub fn report_status(&mut self) {
        let unknown_ops = self.num_requests as u64 - self.committed - self.aborted;

        println!("{:16}:\tCommitted: {:6}\tAborted: {:6}\tUnknown: {:6}", self.id_str.clone(), self.committed, self.aborted, unknown_ops);
    }

    ///
    /// protocol()
    /// Implements the client side of the 2PC protocol. Requests are issued
    /// one at a time, each waiting for its result.
    ///
    pub fn protocol(&mut self, n_requests: u32) {

        while self.num_requests < n_requests && !self.done && self.running.load(Ordering::SeqCst) {
            self.send_next_operation();
            if !self.done {
                self.recv_result();
            }
        }

        self.wait_for_exit_signal();
        self.report_status();
    }
}
