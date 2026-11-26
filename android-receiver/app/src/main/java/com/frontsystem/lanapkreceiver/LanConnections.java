package com.frontsystem.lanapkreceiver;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.Proxy;
import java.net.URI;

/** Use the LAN even when Android prefers cellular because Wi-Fi has no internet. */
final class LanConnections {
    private LanConnections() {}

    @SuppressWarnings("deprecation")
    static HttpURLConnection open(Context context, URI uri) throws IOException {
        ConnectivityManager manager = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (manager != null) {
            Network[] networks = manager.getAllNetworks();
            for (int transport : new int[]{NetworkCapabilities.TRANSPORT_WIFI, NetworkCapabilities.TRANSPORT_ETHERNET}) {
                for (Network network : networks) {
                    NetworkCapabilities capabilities = manager.getNetworkCapabilities(network);
                    if (capabilities != null && capabilities.hasTransport(transport)
                            && !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                        return (HttpURLConnection) network.openConnection(uri.toURL(), Proxy.NO_PROXY);
                    }
                }
            }
        }
        throw new IOException("未连接可用的 Wi-Fi 或有线局域网，请先连接 Mac 所在网络。");
    }
}
