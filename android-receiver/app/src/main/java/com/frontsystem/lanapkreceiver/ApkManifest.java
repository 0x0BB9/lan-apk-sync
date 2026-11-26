package com.frontsystem.lanapkreceiver;

import org.json.JSONException;
import org.json.JSONObject;
import java.io.IOException;
import java.util.Locale;

final class ApkManifest {
    final String fileName;
    final long size;
    final String sha256;
    final String modifiedAt;

    private ApkManifest(String fileName, long size, String sha256, String modifiedAt) {
        this.fileName = fileName;
        this.size = size;
        this.sha256 = sha256;
        this.modifiedAt = modifiedAt;
    }

    static ApkManifest parse(String json) throws IOException {
        try {
            JSONObject data = new JSONObject(json);
            if (!data.has("available") || !(data.get("available") instanceof Boolean)) {
                throw new JSONException("Missing availability");
            }
            if (!data.getBoolean("available")) return null;
            String name = data.getString("fileName");
            String hash = data.getString("sha256").toLowerCase(Locale.ROOT);
            long size = data.getLong("size");
            if (name.length() > 255 || !name.toLowerCase(Locale.ROOT).endsWith(".apk")
                    || name.contains("/") || name.contains("\\") || name.contains("\n")
                    || name.contains("\r") || !hash.matches("[a-f0-9]{64}")
                    || size <= 0 || size > 8L * 1024 * 1024 * 1024
                    || !"download".equals(data.getString("downloadPath"))) {
                throw new JSONException("Invalid manifest");
            }
            return new ApkManifest(name, size, hash, data.optString("modifiedAt", ""));
        } catch (JSONException exception) {
            throw new IOException("Mac 返回的 APK 信息无效，请确认使用 LAN APK Sync 工具。", exception);
        }
    }

    String toJson() {
        try {
            return new JSONObject().put("available", true).put("fileName", fileName)
                    .put("size", size).put("sha256", sha256).put("modifiedAt", modifiedAt)
                    .put("downloadPath", "download").toString();
        } catch (JSONException exception) { throw new IllegalStateException(exception); }
    }
}
