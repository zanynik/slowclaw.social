// LanInterface.cs — pick the machine's primary LAN IPv4 address for the QR.
//
// The listener binds to this address (not 0.0.0.0) to avoid accidental
// exposure on other interfaces (virtual adapters, loopback, etc.). Prefers
// the first up, non-loopback, non-virtual IPv4 address.

using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace SlowClawSync.Sync;

internal static class LanInterface
{
    /// <summary>Return the first LAN IPv4 address, or "127.0.0.1" if none found.</summary>
    public static string DetectLanAddress()
    {
        foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up)
            {
                continue;
            }
            // Skip virtual / loopback adapters.
            if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback)
            {
                continue;
            }
            if (nic.Description.Contains("Virtual", System.StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            IPInterfaceProperties props = nic.GetIPProperties();
            foreach (UnicastIPAddressInformation addr in props.UnicastAddresses)
            {
                if (addr.Address.AddressFamily == AddressFamily.InterNetwork
                    && !IPAddress.IsLoopback(addr.Address))
                {
                    return addr.Address.ToString();
                }
            }
        }
        return "127.0.0.1";
    }
}
