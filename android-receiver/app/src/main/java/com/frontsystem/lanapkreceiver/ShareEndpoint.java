package com.frontsystem.lanapkreceiver;

import java.net.URI;
import java.net.URISyntaxException;

/** A LAN-only, literal IPv4 endpoint. Never resolve arbitrary scanned hosts. */
final class ShareEndpoint {
    final URI base;

    private ShareEndpoint(URI base) {
        this.base = base;
    }

    static ShareEndpoint parse(String input) {
        try {
            if (input == null || input.length() > 2048) throw invalid();
            URI uri = new URI(input.trim());
            if (!"http".equalsIgnoreCase(uri.getScheme()) || uri.getUserInfo() != null
                    || uri.getQuery() != null || uri.getFragment() != null
                    || !isPrivateIpv4(uri.getHost()) || uri.getPort() == 0
                    || uri.getPort() > 65535) throw invalid();
            String path = uri.getRawPath();
            if (path == null || !path.matches("/[A-Za-z0-9_-]{24}/?")) throw invalid();
            if (!path.endsWith("/")) path += "/";
            return new ShareEndpoint(new URI("http", null, uri.getHost(), uri.getPort(),
                    path, null, null));
        } catch (URISyntaxException exception) {
            throw invalid();
        }
    }

    private static IllegalArgumentException invalid() {
        return new IllegalArgumentException("请扫描 Mac 工具的二维码，或输入完整的局域网分享链接。");
    }

    static boolean isPrivateIpv4(String host) {
        if (host == null) return false;
        String[] parts = host.split("\\.", -1);
        if (parts.length != 4) return false;
        int[] values = new int[4];
        for (int index = 0; index < 4; index++) {
            if (!parts[index].matches("0|[1-9][0-9]{0,2}")) return false;
            values[index] = Integer.parseInt(parts[index]);
            if (values[index] > 255) return false;
        }
        return values[0] == 10
                || (values[0] == 172 && values[1] >= 16 && values[1] <= 31)
                || (values[0] == 192 && values[1] == 168);
    }

    URI manifest() { return base.resolve("manifest.json"); }
    URI catalog() { return base.resolve("catalog.json"); }
    URI download() { return base.resolve("download"); }
    URI download(ApkManifest apk) { return base.resolve(apk.downloadPath); }
    String displayAddress() { return base.getHost() + (base.getPort() < 0 ? "" : ":" + base.getPort()); }

    @Override public String toString() { return base.toString(); }
}
