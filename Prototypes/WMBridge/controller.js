"use strict";
// HS2 owns sequencing over Atelier's existing Bridge. Once any mutation was
// submitted, this controller cannot create again, even after a lost response.
class TrialController {
  constructor(bridge) { this.bridge = bridge; this.busy = false; this.attempted = false; this.created = null; }
  async create(runDirectory, enter = false) {
    if (this.busy) return {busy:true};
    if (this.attempted) throw new Error("Reconcile the prior attempt; this controller never replays creation");
    this.busy = true;
    try {
      const probe = await this.bridge.request("wmbridgeProbe");
      if (!probe.bridgeAnswered || !probe.bridgeMatchesCensus || !probe.createABIAvailable) throw new Error("WMBridge unavailable");
      const snapshot = await this.bridge.request("snapshot");
      this.attempted = true;
      this.created = await this.bridge.request("wmbridgeCreate", {runDirectory,display:snapshot.targetDisplay});
      if (this.created.status !== "managed-type0-confirmed" || !enter) return this.created;
      return await this.enter(this.created);
    } finally { this.busy = false; }
  }
  async enter(created) {
    const outcome = {...created, activation:"not-attempted"};
    try {
      const snapshot = await this.bridge.request("snapshot");
      const display = snapshot.displays.find(d => d.id === snapshot.targetDisplay);
      const number = display?.spaces.filter(s => !s.fullscreen).findIndex(s => s.id === created.createdID) + 1;
      if (!number) throw new Error("Created ID absent from current target display");
      const after = await this.bridge.request("switch", {display:display.id,current:display.current,number});
      if (after.displays.find(d => d.id === display.id)?.current !== created.createdID) throw new Error("Destination not verified");
      return {...outcome,activation:"active-ID-verified",activationSnapshot:after};
    } catch (error) { return {...outcome,activation:"failed-or-uncertain",activationError:error.message}; }
  }
}
module.exports = {TrialController};
