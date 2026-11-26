package com.frontsystem.lanapkreceiver;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import org.junit.Test;
import org.junit.Rule;
import org.junit.rules.TemporaryFolder;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.concurrent.atomic.AtomicBoolean;
import static org.junit.Assert.*;

public final class ReceiverTest {
    private static final String TOKEN = "0123456789abcdefghijklmn";
    private static final String BASE = "http://192.168.1.20:8787/" + TOKEN + "/";
    @Rule public TemporaryFolder temporary = new TemporaryFolder();

    @Test public void acceptsMacEndpointAndAddsSlash() {
        ShareEndpoint endpoint = ShareEndpoint.parse("  " + BASE.substring(0, BASE.length() - 1) + "  ");
        assertEquals(BASE, endpoint.toString());
        assertEquals(BASE + "manifest.json", endpoint.manifest().toString());
        assertEquals(BASE + "download", endpoint.download().toString());
        assertEquals("192.168.1.20:8787", endpoint.displayAddress());
        assertFalse(endpoint.displayAddress().contains(TOKEN));
    }

    @Test public void acceptsAllPrivateIpv4Ranges() {
        for (String host : new String[]{"10.0.2.2", "172.16.0.1", "172.31.255.254", "192.168.0.1"}) {
            assertTrue(ShareEndpoint.isPrivateIpv4(host));
        }
    }

    @Test public void rejectsPublicLoopbackAmbiguousAndHostnameAddresses() {
        for (String host : new String[]{"8.8.8.8", "127.0.0.1", "169.254.1.1", "172.15.1.1",
                "172.32.1.1", "192.168.001.1", "192.168.1.256", "localhost", "example.com",
                "192.168.1.1.example.com", "0xc0a80101", "::1"}) {
            assertFalse(host, ShareEndpoint.isPrivateIpv4(host));
        }
    }

    @Test public void rejectsMalformedAndNonShareUrls() {
        String[] invalid = {"", "text", BASE + "download", BASE + "?token=x", BASE + "#x",
                BASE.replace("http:", "https:"), BASE.replace(":8787", ":0"),
                BASE.replace(":8787", ":65536"), BASE.replace("192.168.1.20", "user@192.168.1.20"),
                BASE.replace(TOKEN, "short"), BASE.replace(TOKEN, "%30" + TOKEN.substring(1))};
        for (String value : invalid) assertThrows(value, IllegalArgumentException.class, () -> ShareEndpoint.parse(value));
        assertThrows(IllegalArgumentException.class, () -> ShareEndpoint.parse(null));
    }

    @Test public void handlesEmptyMacDirectory() throws Exception {
        assertNull(ApkManifest.parse("{\"available\":false}"));
    }

    @Test public void parsesRealMacManifestContract() throws Exception {
        byte[] bytes = {1, 2, 3};
        ApkManifest manifest = manifest(bytes);
        assertEquals("测试包.apk", manifest.fileName);
        assertEquals(3, manifest.size);
        assertEquals(hash(bytes), manifest.sha256);
    }

    @Test public void rejectsInvalidOrRedirectedManifestFields() {
        String valid = json(new byte[]{1});
        for (String value : new String[]{"{}", "not json", valid.replace("测试包.apk", "../app.apk"),
                valid.replace("测试包.apk", "app.zip"), valid.replace("\"size\":1", "\"size\":0"),
                valid.replace("\"size\":1", "\"size\":9000000000"),
                valid.replace("\"downloadPath\":\"download\"", "\"downloadPath\":\"http://evil.test/app.apk\""),
                valid.replace(hash(new byte[]{1}), "bad")}) {
            assertThrows(value, IOException.class, () -> ApkManifest.parse(value));
        }
    }

    @Test public void fetchesManifestWithoutFollowingRedirects() throws Exception {
        FakeConnection response = new FakeConnection(200, json(new byte[]{1}).getBytes(StandardCharsets.UTF_8));
        ShareClient client = new ShareClient(uri -> {
            assertEquals(BASE + "manifest.json", uri.toString());
            return response;
        });
        assertNotNull(client.manifest(ShareEndpoint.parse(BASE)));
        assertFalse(response.getInstanceFollowRedirects());
        assertTrue(response.disconnected);
    }

    @Test public void refusesRedirectsAndExpiredLinks() throws Exception {
        for (int code : new int[]{301, 302, 307, 404, 409, 500}) {
            FakeConnection response = new FakeConnection(code, new byte[0]);
            ShareClient client = new ShareClient(uri -> response);
            assertThrows(IOException.class, () -> client.manifest(ShareEndpoint.parse(BASE)));
            assertTrue(response.disconnected);
        }
    }

    @Test public void limitsManifestSize() throws Exception {
        FakeConnection response = new FakeConnection(200, new byte[65537]);
        assertThrows(IOException.class, () -> new ShareClient(uri -> response).manifest(ShareEndpoint.parse(BASE)));
        assertTrue(response.disconnected);
    }

    @Test public void downloadsAndVerifiesBytes() throws Exception {
        byte[] bytes = new byte[200000];
        for (int index = 0; index < bytes.length; index++) bytes[index] = (byte) index;
        FakeConnection response = new FakeConnection(200, bytes);
        File directory = temporary.newFolder();
        long[] progress = {0};
        File file = new ShareClient(uri -> response).download(ShareEndpoint.parse(BASE), manifest(bytes),
                directory, new AtomicBoolean(), (received, total) -> { progress[0] = received; assertEquals(bytes.length, total); });
        assertArrayEquals(bytes, Files.readAllBytes(file.toPath()));
        assertEquals(hash(bytes) + ".apk", file.getName());
        assertEquals(bytes.length, progress[0]);
        assertEquals(1, directory.list().length);
        assertTrue(response.disconnected);
    }

    @Test public void rejectsWrongHashAndDiscardsPartialDownload() throws Exception {
        byte[] expected = {1, 2, 3};
        FakeConnection response = new FakeConnection(200, new byte[]{3, 2, 1});
        File directory = temporary.newFolder();
        assertThrows(IOException.class, () -> new ShareClient(uri -> response).download(ShareEndpoint.parse(BASE),
                manifest(expected), directory, new AtomicBoolean(), (received, total) -> {}));
        assertEquals(0, directory.list().length);
        assertTrue(response.disconnected);
    }

    @Test public void rejectsChangedContentLength() throws Exception {
        FakeConnection response = new FakeConnection(200, new byte[]{1, 2});
        File directory = temporary.newFolder();
        assertThrows(IOException.class, () -> new ShareClient(uri -> response).download(ShareEndpoint.parse(BASE),
                manifest(new byte[]{1}), directory, new AtomicBoolean(), (received, total) -> {}));
        assertEquals(0, directory.list().length);
    }

    @Test public void rejectsTruncatedAndOversizedStreamsWithoutLengthHeader() throws Exception {
        for (byte[] data : new byte[][]{{1}, {1, 2, 3}}) {
            FakeConnection response = new FakeConnection(200, data);
            response.length = -1;
            File directory = temporary.newFolder();
            assertThrows(IOException.class, () -> new ShareClient(uri -> response).download(ShareEndpoint.parse(BASE),
                    manifest(new byte[]{1, 2}), directory, new AtomicBoolean(), (received, total) -> {}));
            assertEquals(0, directory.list().length);
        }
    }

    @Test public void cancelsAndDiscardsPartialDownload() throws Exception {
        byte[] bytes = new byte[150000];
        FakeConnection response = new FakeConnection(200, bytes);
        File directory = temporary.newFolder();
        AtomicBoolean cancel = new AtomicBoolean();
        assertThrows(IOException.class, () -> new ShareClient(uri -> response).download(ShareEndpoint.parse(BASE),
                manifest(bytes), directory, cancel, (received, total) -> cancel.set(true)));
        assertEquals(0, directory.list().length);
    }

    @Test public void decodesBundledQrWithoutNetwork() throws Exception {
        BitMatrix matrix = new QRCodeWriter().encode(BASE, BarcodeFormat.QR_CODE, 500, 500);
        int[] pixels = pixels(matrix, false, false);
        assertEquals(BASE, QrDecoder.image(pixels, 500, 500));
    }

    @Test public void decodesRotatedAndInvertedQr() throws Exception {
        BitMatrix matrix = new QRCodeWriter().encode(BASE, BarcodeFormat.QR_CODE, 500, 500);
        assertEquals(BASE, QrDecoder.image(pixels(matrix, true, false), 500, 500));
        assertEquals(BASE, QrDecoder.image(pixels(matrix, false, true), 500, 500));
    }

    @Test public void decodesCameraLuminanceFrame() throws Exception {
        BitMatrix matrix = new QRCodeWriter().encode(BASE, BarcodeFormat.QR_CODE, 500, 500);
        byte[] yuv = new byte[500 * 500 * 3 / 2];
        for (int y = 0; y < 500; y++) for (int x = 0; x < 500; x++) yuv[y * 500 + x] = (byte) (matrix.get(x, y) ? 0 : 255);
        assertEquals(BASE, QrDecoder.frame(yuv, 500, 500));
    }

    private int[] pixels(BitMatrix matrix, boolean rotate, boolean invert) {
        int[] pixels = new int[500 * 500];
        for (int y = 0; y < 500; y++) for (int x = 0; x < 500; x++) {
            boolean black = rotate ? matrix.get(y, 499 - x) : matrix.get(x, y);
            pixels[y * 500 + x] = black != invert ? 0xff000000 : 0xffffffff;
        }
        return pixels;
    }

    private static String hash(byte[] data) { return ShareClient.hex(ShareClient.sha256().digest(data)); }
    private static ApkManifest manifest(byte[] data) throws IOException { return ApkManifest.parse(json(data)); }
    private static String json(byte[] data) {
        return "{\"available\":true,\"fileName\":\"测试包.apk\",\"size\":" + data.length
                + ",\"sha256\":\"" + hash(data) + "\",\"modifiedAt\":\"2026-01-01T00:00:00Z\",\"downloadPath\":\"download\"}";
    }

    private static final class FakeConnection extends HttpURLConnection {
        private final byte[] bytes;
        boolean disconnected;
        long length;
        FakeConnection(int code, byte[] bytes) throws Exception {
            super(new URL("http://192.168.1.20/"));
            responseCode = code;
            this.bytes = bytes;
            length = bytes.length;
        }
        @Override public int getResponseCode() { return responseCode; }
        @Override public long getContentLengthLong() { return length; }
        @Override public String getHeaderField(String name) {
            return "Content-Length".equalsIgnoreCase(name) && length >= 0 ? Long.toString(length) : null;
        }
        @Override public InputStream getInputStream() { return new ByteArrayInputStream(bytes); }
        @Override public void disconnect() { disconnected = true; }
        @Override public boolean usingProxy() { return false; }
        @Override public void connect() { }
    }
}
