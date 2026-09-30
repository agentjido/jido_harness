// Protocol fixture for the pinned supervisor's synchronous crash callback.
export class ProcessSupervisor {
  constructor(forward) {
    this.forwardInbound = forward;
    this.needsRecycle = false;
  }

  declareHang(sessionId, promptId, reason) {
    this.needsRecycle = true;
    this.forwardInbound({
      jsonrpc: "2.0",
      id: promptId,
      result: { stopReason: "end_turn" },
    });
  }
}
