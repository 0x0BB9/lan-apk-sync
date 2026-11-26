package com.frontsystem.lanapkreceiver;

import org.json.JSONException;
import org.json.JSONObject;
import org.json.JSONArray;
import java.io.IOException;
import java.util.Locale;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;

final class ApkManifest {
    final String fileName;
    final long size;
    final String sha256;
    final String modifiedAt;
    final String id;
    final String downloadPath;

    private ApkManifest(String fileName, long size, String sha256, String modifiedAt, String id, String downloadPath) {
        this.fileName = fileName;
        this.size = size;
        this.sha256 = sha256;
        this.modifiedAt = modifiedAt;
        this.id = id;
        this.downloadPath = downloadPath;
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
            String id = data.optString("id", hash);
            String path = data.getString("downloadPath");
            long size = data.getLong("size");
            if (name.length() > 255 || !name.toLowerCase(Locale.ROOT).endsWith(".apk")
                    || name.contains("/") || name.contains("\\") || name.contains("\n")
                    || name.contains("\r") || !hash.matches("[a-f0-9]{64}")
                    || size <= 0 || size > 8L * 1024 * 1024 * 1024
                    || !id.matches("[a-f0-9]{64}")
                    || !("download".equals(path) || path.equals("apks/" + id + "/download?sha256=" + hash))) {
                throw new JSONException("Invalid manifest");
            }
            return new ApkManifest(name, size, hash, data.optString("modifiedAt", ""), id, path);
        } catch (JSONException exception) {
            throw new IOException("Mac 返回的 APK 信息无效，请确认使用 LAN APK Sync 工具。", exception);
        }
    }

    static List<ApkManifest> parseCatalog(String json) throws IOException {
        try {
            JSONObject data = new JSONObject(json);
            if (data.getInt("schemaVersion") != 2) throw new JSONException("Unsupported catalog");
            JSONArray array = data.getJSONArray("apks");
            if (array.length() > 1000) throw new JSONException("Too many APKs");
            List<ApkManifest> result = new ArrayList<>();
            HashSet<String> ids = new HashSet<>();
            for (int index = 0; index < array.length(); index++) {
                ApkManifest apk = parse(array.getJSONObject(index).toString());
                if (apk == null || !ids.add(apk.id)) throw new JSONException("Invalid or duplicate APK");
                result.add(apk);
            }
            return result;
        } catch (JSONException exception) {
            throw new IOException("Mac 返回的 APK 列表无效，请检查共享工具版本。", exception);
        }
    }

    String toJson() {
        try {
            return new JSONObject().put("available", true).put("fileName", fileName)
                    .put("size", size).put("sha256", sha256).put("modifiedAt", modifiedAt)
                    .put("id", id).put("downloadPath", downloadPath).toString();
        } catch (JSONException exception) { throw new IllegalStateException(exception); }
    }
}
