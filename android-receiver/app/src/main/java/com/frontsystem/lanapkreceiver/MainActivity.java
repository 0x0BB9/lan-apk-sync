package com.frontsystem.lanapkreceiver;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.InputType;
import android.view.View;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import androidx.core.content.FileProvider;
import java.io.File;
import java.io.IOException;
import java.util.Locale;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

@android.annotation.SuppressLint("SetTextI18n") // This internal tool has a Chinese-only UI.
public final class MainActivity extends Activity {
    private static final int SCAN = 10;
    private static final int CAMERA_PERMISSION = 11;
    private static final int GREEN = 0xff176747;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final ShareClient client = new ShareClient(uri -> LanConnections.open(this, uri));
    private final AtomicBoolean cancelled = new AtomicBoolean();
    private SharedPreferences preferences;
    private ShareEndpoint endpoint;
    private ApkManifest manifest;
    private List<ApkManifest> manifests = new ArrayList<>();
    private String selectedId;
    private RadioGroup choices;
    private String choicesSignature = "";
    private boolean updatingChoices;
    private File verifiedApk;
    private boolean fetching;
    private boolean downloading;
    private boolean resumed;
    private boolean waitingForInstallPermission;
    private TextView connection;
    private TextView details;
    private TextView status;
    private Button scan;
    private Button manual;
    private Button forget;
    private Button refresh;
    private Button download;
    private Button cancel;
    private ProgressBar progress;
    private final Runnable poll = new Runnable() {
        @Override public void run() {
            if (!resumed) return;
            fetch();
            handler.postDelayed(this, 5000);
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        preferences = getSharedPreferences("lan_share", MODE_PRIVATE);
        selectedId = preferences.getString("selected_id", "");
        String saved = preferences.getString("endpoint", "");
        if (!saved.isEmpty()) {
            try { endpoint = ShareEndpoint.parse(saved); }
            catch (IllegalArgumentException ignored) { preferences.edit().remove("endpoint").apply(); }
        }
        if (state != null && saved.equals(state.getString("endpoint")) && state.containsKey("verified_manifest")) {
            try {
                ApkManifest restored = ApkManifest.parse(state.getString("verified_manifest"));
                if (restored != null) {
                    File file = new File(getFilesDir(), "apks/" + restored.sha256 + ".apk");
                    if (file.isFile() && file.length() == restored.size) {
                        manifest = restored;
                        selectedId = restored.id;
                        verifiedApk = file;
                        waitingForInstallPermission = state.getBoolean("waiting_install");
                    }
                }
            } catch (IOException ignored) { /* Safely retry the download if state is invalid. */ }
        }
        createUi();
        render();
    }

    private void createUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(0xfff4f7f3);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars()
                        | WindowInsets.Type.displayCutout());
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            } else {
                view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                        insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            }
            return insets;
        });
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(24), dp(30), dp(24), dp(24));
        addText(content, "LAN APK SYNC  /  ANDROID", 12, GREEN, true);
        TextView heading = addText(content, "局域网接包", 32, 0xff182b22, true);
        heading.setPadding(0, dp(12), 0, dp(6));
        addText(content, "扫码连接 Mac，直接接收测试包。\n无需浏览器，也无需外网。", 15, 0xff59695f, false);

        LinearLayout source = card(content);
        addText(source, "01  连接开发机", 16, GREEN, true);
        connection = addText(source, "", 17, 0xff182b22, true);
        connection.setPadding(0, dp(12), 0, dp(10));
        scan = button(source, "扫描 Mac 二维码", true, this::scan);
        manual = button(source, "手动输入分享链接", false, this::manualInput);
        forget = button(source, "忘记当前连接", false, () -> new AlertDialog.Builder(this)
                .setTitle("忘记连接？").setMessage("只清除本机保存的入口，不会重置 Mac 的分享链接。")
                .setNegativeButton("取消", null).setPositiveButton("忘记", (dialog, which) -> {
                    endpoint = null;
                    manifest = null;
                    manifests.clear();
                    selectedId = "";
                    verifiedApk = null;
                    preferences.edit().remove("endpoint").remove("selected_id").apply();
                    setStatus("连接已清除，请重新扫码。", false);
                    render();
                }).show());

        LinearLayout apk = card(content);
        addText(apk, "02  获取最新测试包", 16, GREEN, true);
        choices = new RadioGroup(this);
        choices.setOrientation(RadioGroup.VERTICAL);
        apk.addView(choices, new LinearLayout.LayoutParams(-1, -2));
        choices.setOnCheckedChangeListener((group, checkedId) -> {
            if (updatingChoices || downloading || fetching) return;
            RadioButton item = group.findViewById(checkedId);
            if (item == null) return;
            for (ApkManifest candidate : manifests) {
                if (candidate.id.equals(item.getTag())) {
                    if (manifest == null || !manifest.id.equals(candidate.id)
                            || !manifest.sha256.equals(candidate.sha256)) verifiedApk = null;
                    manifest = candidate;
                    selectedId = candidate.id;
                    waitingForInstallPermission = false;
                    preferences.edit().putString("selected_id", selectedId).apply();
                    setStatus("已选择 " + candidate.fileName + "，点击下载并安装。", false);
                    render();
                    break;
                }
            }
        });
        details = addText(apk, "", 15, 0xff182b22, false);
        details.setTextIsSelectable(true);
        details.setPadding(0, dp(14), 0, dp(12));
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(100);
        progress.setVisibility(View.GONE);
        apk.addView(progress, new LinearLayout.LayoutParams(-1, dp(8)));
        status = addText(apk, "扫码一次，之后打开应用自动检查最新包。", 14, 0xff59695f, false);
        status.setPadding(0, dp(12), 0, dp(10));
        download = button(apk, "下载并安装", true, this::download);
        refresh = button(apk, "检查最新包", false, this::fetch);
        cancel = button(apk, "取消下载", false, () -> {
            cancelled.set(true);
            cancel.setEnabled(false);
            setStatus("正在取消下载…", false);
        });
        cancel.setVisibility(View.GONE);
        addText(content, "仅连接 Mac 的私有 IPv4 地址；HTTP 传输请使用可信 Wi-Fi。\n"
                + "下载后校验 SHA-256，再交由系统安装。首次需允许本应用安装未知应用；"
                + "若小米系统仍要求账号，本工具不能绕过。", 12, 0xff657368, false);
        button(content, "开源许可", false, this::showLicenses);
        scroll.addView(content);
        root.addView(scroll, new LinearLayout.LayoutParams(-1, -1));
        setContentView(root);
        root.requestApplyInsets();
    }

    private LinearLayout card(LinearLayout parent) {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setPadding(dp(18), dp(20), dp(18), dp(18));
        GradientDrawable background = new GradientDrawable();
        background.setColor(Color.WHITE);
        background.setCornerRadius(dp(18));
        background.setStroke(dp(1), 0xffdee7dd);
        card.setBackground(background);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2);
        params.topMargin = dp(22);
        params.bottomMargin = dp(8);
        parent.addView(card, params);
        return card;
    }

    private TextView addText(LinearLayout parent, String text, int size, int color, boolean bold) {
        TextView label = new TextView(this);
        label.setText(text);
        label.setTextSize(size);
        label.setTextColor(color);
        label.setLineSpacing(dp(3), 1);
        if (bold) label.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        parent.addView(label, new LinearLayout.LayoutParams(-1, -2));
        return label;
    }

    private Button button(LinearLayout parent, String label, boolean primary, Runnable action) {
        Button button = new Button(this);
        button.setText(label);
        button.setTextSize(15);
        button.setAllCaps(false);
        button.setTextColor(primary ? Color.WHITE : GREEN);
        button.setBackgroundTintList(android.content.res.ColorStateList.valueOf(primary ? GREEN : 0xffedf3ec));
        button.setOnClickListener(view -> action.run());
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, dp(52));
        params.topMargin = dp(6);
        parent.addView(button, params);
        return button;
    }

    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }

    private void showLicenses() {
        try (java.io.InputStream input = getAssets().open("NOTICE.txt")) {
            java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream();
            byte[] bytes = new byte[4096];
            int count;
            while ((count = input.read(bytes)) != -1) output.write(bytes, 0, count);
            new AlertDialog.Builder(this).setTitle("开源许可")
                    .setMessage(new String(output.toByteArray(), java.nio.charset.StandardCharsets.UTF_8))
                    .setPositiveButton("关闭", null).show();
        } catch (IOException exception) { setStatus("无法读取许可文件。", true); }
    }

    private void render() {
        boolean busy = fetching || downloading;
        renderChoices(busy);
        connection.setText(endpoint == null ? "尚未连接 Mac" : "已保存  " + endpoint.displayAddress());
        details.setText(manifest == null ? (endpoint == null ? "连接后显示 APK 信息。" : "等待 Mac 发布 APK…")
                : manifest.fileName + "\n" + formatSize(manifest.size)
                + "\nSHA-256\n" + manifest.sha256);
        scan.setEnabled(!busy);
        manual.setEnabled(!busy);
        forget.setVisibility(endpoint == null ? View.GONE : View.VISIBLE);
        forget.setEnabled(!busy);
        refresh.setEnabled(endpoint != null && !busy);
        download.setEnabled(manifest != null && !busy);
        download.setText(verifiedApk != null ? "安装已校验的 APK" : "下载并安装");
        cancel.setVisibility(downloading ? View.VISIBLE : View.GONE);
        cancel.setEnabled(downloading && !cancelled.get());
        progress.setVisibility(downloading ? View.VISIBLE : View.GONE);
        getWindow().getDecorView().setKeepScreenOn(downloading);
    }

    private void renderChoices(boolean busy) {
        StringBuilder signature = new StringBuilder();
        for (ApkManifest apk : manifests) signature.append(apk.id).append(apk.sha256).append(apk.fileName);
        updatingChoices = true;
        if (!choicesSignature.equals(signature.toString())) {
            choicesSignature = signature.toString();
            choices.removeAllViews();
            for (ApkManifest apk : manifests) {
                RadioButton option = new RadioButton(this);
                option.setId(View.generateViewId());
                option.setTag(apk.id);
                option.setText(apk.fileName + "  ·  " + formatSize(apk.size) + "\nID " + apk.id.substring(0, 8));
                option.setTextSize(14);
                option.setTextColor(0xff182b22);
                option.setPadding(0, dp(10), 0, dp(10));
                choices.addView(option, new RadioGroup.LayoutParams(-1, -2));
            }
        }
        for (int index = 0; index < choices.getChildCount(); index++) {
            RadioButton option = (RadioButton) choices.getChildAt(index);
            option.setEnabled(!busy);
            if (option.getTag().equals(selectedId)) option.setChecked(true);
        }
        updatingChoices = false;
    }

    private void setStatus(String message, boolean error) {
        status.setText(message);
        status.setTextColor(error ? 0xffb03b2e : 0xff59695f);
    }

    private void scan() {
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            new AlertDialog.Builder(this).setTitle("允许相机扫码")
                    .setMessage(R.string.camera_reason).setNegativeButton("取消", null)
                    .setPositiveButton("继续", (dialog, which) -> requestPermissions(
                            new String[]{Manifest.permission.CAMERA}, CAMERA_PERMISSION)).show();
        } else {
            startActivityForResult(new Intent(this, ScanActivity.class), SCAN);
        }
    }

    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request == CAMERA_PERMISSION) {
            if (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) scan();
            else new AlertDialog.Builder(this).setTitle("相机权限未开启")
                    .setMessage("可以手动输入分享链接，或前往系统设置允许相机权限。")
                    .setNegativeButton("取消", null).setPositiveButton("应用设置", (dialog, which) ->
                            startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:" + getPackageName())))).show();
        }
    }

    private void manualInput() {
        EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI
                | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        input.setHint("粘贴 Mac 工具的完整分享链接");
        input.setPadding(dp(20), dp(18), dp(20), dp(18));
        input.setSaveEnabled(false);
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("输入分享链接")
                .setView(input).setNegativeButton("取消", null).setPositiveButton("连接", null).create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(view -> {
            try {
                ShareEndpoint candidate = ShareEndpoint.parse(input.getText().toString());
                dialog.dismiss();
                confirmEndpoint(candidate);
            } catch (IllegalArgumentException exception) { input.setError(exception.getMessage()); }
        }));
        dialog.show();
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == SCAN && result == RESULT_OK && data != null) {
            try { confirmEndpoint(ShareEndpoint.parse(data.getStringExtra(ScanActivity.RESULT_URL))); }
            catch (IllegalArgumentException exception) { setStatus(exception.getMessage(), true); }
        }
    }

    private void confirmEndpoint(ShareEndpoint candidate) {
        new AlertDialog.Builder(this).setTitle("连接这台 Mac？")
                .setMessage(candidate.displayAddress() + "\n\n请确认这是可信的开发机。连接后会保存入口，下次无需再扫码。")
                .setNegativeButton("取消", null).setPositiveButton("连接并保存", (dialog, which) -> {
                    endpoint = candidate;
                    manifest = null;
                    manifests.clear();
                    selectedId = "";
                    verifiedApk = null;
                    preferences.edit().putString("endpoint", candidate.toString()).remove("selected_id").apply();
                    render();
                    fetch();
                }).show();
    }

    private void fetch() {
        if (endpoint == null || fetching || downloading) return;
        ShareEndpoint requested = endpoint;
        fetching = true;
        render();
        worker.execute(() -> {
            try {
                List<ApkManifest> catalog = client.catalog(requested);
                post(() -> {
                    fetching = false;
                    if (endpoint != requested) { render(); return; }
                    ApkManifest latest = null;
                    for (ApkManifest candidate : catalog) if (candidate.id.equals(selectedId)) latest = candidate;
                    if (latest == null && !catalog.isEmpty()) latest = catalog.get(0);
                    if (latest == null || manifest == null || !manifest.id.equals(latest.id)
                            || !manifest.sha256.equals(latest.sha256)) verifiedApk = null;
                    manifests = catalog;
                    manifest = latest;
                    selectedId = latest == null ? "" : latest.id;
                    preferences.edit().putString("selected_id", selectedId).apply();
                    if (!waitingForInstallPermission) setStatus(latest == null
                            ? "已连接 Mac，等待生成 APK。页面每 5 秒检查一次。"
                            : "可选 " + catalog.size() + " 个 APK，请选择后下载。", false);
                    render();
                });
            } catch (IOException exception) {
                post(() -> {
                    fetching = false;
                    if (endpoint == requested) {
                        manifest = null;
                        manifests.clear();
                        verifiedApk = null;
                        setStatus(networkError(exception), true);
                    }
                    render();
                });
            }
        });
    }

    private void download() {
        if (manifest == null || endpoint == null || downloading || fetching) return;
        if (verifiedApk != null && verifiedApk.isFile()) { install(); return; }
        ApkManifest selected = manifest;
        ShareEndpoint source = endpoint;
        downloading = true;
        cancelled.set(false);
        progress.setProgress(0);
        render();
        setStatus("正在从 Mac 下载…", false);
        worker.execute(() -> {
            try {
                long[] lastUpdate = {0};
                File file = client.download(source, selected, new File(getFilesDir(), "apks"), cancelled,
                        (received, total) -> {
                            long now = System.nanoTime();
                            if (now - lastUpdate[0] < 150_000_000 && received != total) return;
                            lastUpdate[0] = now;
                            post(() -> {
                                int percent = (int) (received * 100 / total);
                                progress.setProgress(percent);
                                setStatus("下载 " + percent + "%  ·  " + formatSize(received)
                                        + " / " + formatSize(total), false);
                            });
                        });
                // Parse the archive before offering it to the system installer.
                PackageInfo info = getPackageManager().getPackageArchiveInfo(file.getAbsolutePath(), 0);
                if (info == null) {
                    if (!file.delete()) file.deleteOnExit();
                    throw new IOException("文件校验通过，但不是有效的 Android APK，请检查 Mac 输出。");
                }
                post(() -> {
                    downloading = false;
                    verifiedApk = file;
                    setStatus("SHA-256 校验通过，准备安装。", false);
                    render();
                    if (resumed) install();
                });
            } catch (IOException exception) {
                post(() -> {
                    downloading = false;
                    setStatus(networkError(exception), true);
                    render();
                });
            }
        });
    }

    private void install() {
        if (verifiedApk == null || !verifiedApk.isFile()) return;
        if (Build.VERSION.SDK_INT >= 26 && !getPackageManager().canRequestPackageInstalls()) {
            waitingForInstallPermission = true;
            new AlertDialog.Builder(this).setTitle("允许安装测试包")
                    .setMessage("请在下一页允许“局域网接包”安装未知应用。返回后会继续安装，不需要重新下载。"
                            + "\n\n如果小米系统要求账号，需由设备管理员处理；更换下载来源不能保证解除限制。")
                    .setNegativeButton("稍后", (dialog, which) -> waitingForInstallPermission = false)
                    .setOnCancelListener(dialog -> waitingForInstallPermission = false)
                    .setPositiveButton("打开授权设置", (dialog, which) -> {
                        try { startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:" + getPackageName()))); }
                        catch (ActivityNotFoundException exception) {
                            waitingForInstallPermission = false;
                            setStatus("系统未提供安装授权页面，请在应用设置中手动开启。", true);
                        }
                    }).show();
            return;
        }
        waitingForInstallPermission = false;
        Uri uri = FileProvider.getUriForFile(this, getPackageName() + ".files", verifiedApk);
        Intent intent = new Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        intent.setClipData(android.content.ClipData.newRawUri("APK", uri));
        try {
            startActivity(intent);
            setStatus("已交给系统安装器，请在系统页面确认；本应用不执行静默安装。", false);
        } catch (ActivityNotFoundException | SecurityException exception) {
            setStatus("系统拒绝打开安装器，请检查安装权限或设备管理策略。", true);
        }
    }

    private void post(Runnable action) { handler.post(() -> { if (!isDestroyed()) action.run(); }); }

    private String networkError(IOException exception) {
        if (exception instanceof java.net.SocketTimeoutException || exception instanceof java.net.ConnectException
                || exception instanceof java.net.NoRouteToHostException || exception instanceof java.net.UnknownHostException) {
            return "无法连接 Mac。请检查同一 Wi-Fi、Mac 共享是否开启、IP/端口和防火墙；无外网的 Wi-Fi 请保持连接。";
        }
        String message = exception.getMessage();
        // Do not expose networking exception messages that may contain the access token.
        return message != null && !message.contains("://") && message.matches(".*[\\u4e00-\\u9fff].*")
                ? message : "网络传输中断，请检查 Mac 和 Wi-Fi 后重试。";
    }

    static String formatSize(long bytes) {
        return String.format(Locale.CHINA, "%.1f MB", bytes / 1048576.0);
    }

    @Override protected void onResume() {
        super.onResume();
        resumed = true;
        if (waitingForInstallPermission && Build.VERSION.SDK_INT >= 26
                && getPackageManager().canRequestPackageInstalls()) install();
        handler.removeCallbacks(poll);
        handler.post(poll);
    }

    @Override protected void onPause() {
        resumed = false;
        handler.removeCallbacks(poll);
        super.onPause();
    }

    @Override protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        if (endpoint != null && manifest != null && verifiedApk != null) {
            state.putString("endpoint", endpoint.toString());
            state.putString("verified_manifest", manifest.toJson());
            state.putBoolean("waiting_install", waitingForInstallPermission);
        }
    }

    @Override protected void onDestroy() {
        cancelled.set(true);
        worker.shutdownNow();
        handler.removeCallbacksAndMessages(null);
        super.onDestroy();
    }
}
