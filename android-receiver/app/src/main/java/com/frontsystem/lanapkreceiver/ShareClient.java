package com.frontsystem.lanapkreceiver;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.concurrent.atomic.AtomicBoolean;

final class ShareClient {
    interface ConnectionFactory { HttpURLConnection open(URI uri) throws IOException; }
    interface Progress { void update(long received, long total); }
    private final ConnectionFactory connections;

    ShareClient() { this(uri -> (HttpURLConnection) uri.toURL().openConnection()); }
    ShareClient(ConnectionFactory connections) { this.connections = connections; }

    private HttpURLConnection connect(URI uri) throws IOException {
        HttpURLConnection connection = connections.open(uri);
        connection.setInstanceFollowRedirects(false);
        connection.setConnectTimeout(8000);
        connection.setReadTimeout(20000);
        connection.setUseCaches(false);
        connection.setRequestProperty("Accept-Encoding", "identity");
        try {
            int status = connection.getResponseCode();
            if (status == 404) throw new IOException("分享入口失效或 APK 尚未就绪，请检查 Mac，必要时重新扫码。");
            if (status == 409) throw new IOException("Mac 正在更新 APK，请稍后重试。");
            if (status != 200) throw new IOException("Mac 服务返回 HTTP " + status + "，请检查共享状态。");
            return connection;
        } catch (IOException exception) {
            connection.disconnect();
            throw exception;
        }
    }

    ApkManifest manifest(ShareEndpoint endpoint) throws IOException {
        HttpURLConnection connection = connect(endpoint.manifest());
        try (InputStream input = connection.getInputStream();
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int count;
            while ((count = input.read(buffer)) != -1) {
                if (output.size() + count > 65536) throw new IOException("APK 信息过大，已拒绝读取。");
                output.write(buffer, 0, count);
            }
            return ApkManifest.parse(new String(output.toByteArray(), StandardCharsets.UTF_8));
        } finally {
            connection.disconnect();
        }
    }

    @android.annotation.SuppressLint("UsableSpace") // Conservative check; do not evict other apps' caches.
    File download(ShareEndpoint endpoint, ApkManifest manifest, File directory,
                  AtomicBoolean cancelled, Progress progress) throws IOException {
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("无法创建下载目录。");
        if (directory.getUsableSpace() < manifest.size + 16 * 1024 * 1024) {
            throw new IOException("手机存储空间不足，请清理后重试。");
        }
        File partial = new File(directory, manifest.sha256 + ".part");
        File target = new File(directory, manifest.sha256 + ".apk");
        boolean complete = false;
        HttpURLConnection connection = connect(endpoint.download());
        try {
            long advertised = -1;
            String lengthHeader = connection.getHeaderField("Content-Length");
            if (lengthHeader != null) {
                try { advertised = Long.parseLong(lengthHeader); }
                catch (NumberFormatException exception) { throw new IOException("下载大小信息无效。"); }
                if (advertised < 0) throw new IOException("下载大小信息无效。");
            }
            if (advertised != -1 && advertised != manifest.size) {
                throw new IOException("APK 已发生变化，请刷新后重新下载。");
            }
            MessageDigest digest = sha256();
            long received = 0;
            try (InputStream input = connection.getInputStream();
                 FileOutputStream output = new FileOutputStream(partial)) {
                byte[] buffer = new byte[65536];
                int count;
                while ((count = input.read(buffer)) != -1) {
                    if (cancelled.get() || Thread.currentThread().isInterrupted()) throw new IOException("下载已取消。");
                    received += count;
                    if (received > manifest.size) throw new IOException("下载大小与 Mac 信息不符，已停止。");
                    output.write(buffer, 0, count);
                    digest.update(buffer, 0, count);
                    progress.update(received, manifest.size);
                }
                output.getFD().sync();
            }
            if (cancelled.get()) throw new IOException("下载已取消。");
            if (received != manifest.size || !hex(digest.digest()).equals(manifest.sha256)) {
                throw new IOException("APK 校验失败，文件已丢弃。请刷新后重新下载。");
            }
            if (!partial.renameTo(target)) throw new IOException("无法保存已校验的 APK。");
            complete = true;
            return target;
        } finally {
            connection.disconnect();
            if (!complete && partial.exists() && !partial.delete()) partial.deleteOnExit();
        }
    }

    static MessageDigest sha256() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException exception) { throw new IllegalStateException(exception); }
    }

    static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) result.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
        return result.toString();
    }
}
