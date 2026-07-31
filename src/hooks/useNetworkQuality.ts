import { useEffect, useState, useCallback } from 'react';
import { NetworkQualityMonitor, NetworkQuality } from '../utils/networkOptimization';

let globalMonitor: NetworkQualityMonitor | null = null;

function getGlobalMonitor(): NetworkQualityMonitor {
  if (!globalMonitor) {
    globalMonitor = new NetworkQualityMonitor();
  }
  return globalMonitor;
}

export function useNetworkQuality() {
  const [quality, setQuality] = useState<NetworkQuality>({
    latency: 0,
    bandwidth: 'medium',
    isOnline: navigator.onLine,
    isGoodConnection: true,
  });

  const [showNetworkWarning, setShowNetworkWarning] = useState(false);

  useEffect(() => {
    const monitor = getGlobalMonitor();

    // READS THE RESULT BACK. It used to define a handleQualityChange callback
    // here and never give it to anything.
    //
    // NetworkQualityMonitor takes an onQualityChange callback in its CONSTRUCTOR
    // and invokes it whenever it recomputes quality -- but getGlobalMonitor()
    // builds it with `new NetworkQualityMonitor()`, no argument. So the callback
    // was undefined forever and the handler defined below it was unreachable
    // code that TypeScript reported only as "declared but never read".
    //
    // The effect was not cosmetic. `quality` and `showNetworkWarning` are what
    // NetworkQualityIndicator renders, and neither ever changed from its initial
    // useState value: the indicator showed a fabricated "good connection" for the
    // life of the session and the warning could not fire. On a game played over
    // Ethiopian mobile networks, an indicator that always says the connection is
    // fine is worse than not having one.
    //
    // Reading getQuality() after each measurement fixes it without adding a
    // subscriber list to a singleton that several components share -- the monitor
    // already stores the value, it simply had nobody asking for it.
    const sync = async () => {
      await monitor.measureLatency();
      const current = monitor.getQuality();
      setQuality(current);
      setShowNetworkWarning(!current.isGoodConnection);
    };

    void sync();

    const interval = setInterval(() => { void sync(); }, 30000);

    return () => clearInterval(interval);
  }, []);

  const isLowBandwidth = useCallback(() => {
    return getGlobalMonitor().isLowBandwidth();
  }, []);

  const isHighLatency = useCallback(() => {
    return getGlobalMonitor().isHighLatency();
  }, []);

  const shouldBatch = useCallback(() => {
    return getGlobalMonitor().shouldBatch();
  }, []);

  const shouldReducePolling = useCallback(() => {
    return getGlobalMonitor().shouldReducePolling();
  }, []);

  return {
    quality,
    showNetworkWarning,
    isLowBandwidth,
    isHighLatency,
    shouldBatch,
    shouldReducePolling,
  };
}
