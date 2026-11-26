package com.frontsystem.lanapkreceiver;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.RadioButton;
import androidx.core.content.FileProvider;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import java.io.File;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

/** On-device checks, optionally against the real Mac server with -e endpoint <URL>. */
public final class ReceiverInstrumentation extends Instrumentation {
    private Bundle arguments;

    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        this.arguments = arguments;
        start();
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        int passed = 0;
        try {
            String url = "http://192.168.1.20:8787/0123456789abcdefghijklmn/";
            BitMatrix code = new QRCodeWriter().encode(url, BarcodeFormat.QR_CODE, 500, 500);
            int[] pixels = new int[250000];
            for (int y = 0; y < 500; y++) for (int x = 0; x < 500; x++) {
                pixels[y * 500 + x] = code.get(x, y) ? 0xff000000 : 0xffffffff;
            }
            check(url.equals(QrDecoder.image(pixels, 500, 500)), "On-device offline QR decode");
            passed++;
            Context context = getTargetContext();
            boolean refused = false;
            try {
                FileProvider.getUriForFile(context, context.getPackageName() + ".files",
                        new File(context.getFilesDir(), "private-preferences.xml"));
            } catch (IllegalArgumentException expected) { refused = true; }
            check(refused, "FileProvider must reject files outside apks/");
            passed++;
            String endpointArg = arguments.getString("endpoint");
            if (endpointArg != null) {
                ShareEndpoint endpoint = ShareEndpoint.parse(endpointArg);
                ShareClient client = new ShareClient(uri -> LanConnections.open(context, uri));
                List<ApkManifest> apks = client.catalog(endpoint);
                check(!apks.isEmpty(), "Mac catalog is available");
                for (ApkManifest manifest : apks) {
                    File apk = client.download(endpoint, manifest, new File(context.getFilesDir(), "apks"),
                            new java.util.concurrent.atomic.AtomicBoolean(), (received, total) -> {});
                    check(context.getPackageManager().getPackageArchiveInfo(apk.getAbsolutePath(), 0) != null,
                            "Each real APK parses after independent transfer and checksum");
                }
                passed++;
                if (arguments.getString("requireMultiple") != null) {
                    check(apks.size() >= 2, "Two APKs are simultaneously available");
                    check(!apks.get(0).id.equals(apks.get(1).id), "APKs have independent identities");
                    passed++;
                }
                ApkManifest selected = apks.get(apks.size() - 1);

                context.getSharedPreferences("lan_share", Context.MODE_PRIVATE).edit()
                        .putString("endpoint", endpoint.toString()).commit();
                Activity activity = startActivitySync(new Intent(context, MainActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                waitForIdleSync();
                waitForDownloadButton(activity);
                runOnMainSync(() -> {
                    RadioButton option = activity.getWindow().getDecorView().findViewWithTag(selected.id);
                    check(option != null, "Selected APK is listed on the phone");
                    option.performClick();
                    check(option.isChecked(), "User can select the second APK");
                });
                waitForDownloadButton(activity);
                // Intercept the installer intent: verify that the client never opens a browser.
                AtomicReference<Intent> installation = new AtomicReference<>();
                ActivityMonitor monitor = new ActivityMonitor() {
                    @Override public ActivityResult onStartActivity(Intent intent) {
                        if ("application/vnd.android.package-archive".equals(intent.getType())) {
                            installation.set(intent);
                            return new ActivityResult(Activity.RESULT_CANCELED, null);
                        }
                        return null;
                    }
                };
                addMonitor(monitor);
                runOnMainSync(() -> button(activity.getWindow().getDecorView(), "下载并安装").performClick());
                long deadline = System.currentTimeMillis() + 30000;
                while (installation.get() == null && System.currentTimeMillis() < deadline) Thread.sleep(100);
                Intent intent = installation.get();
                check(intent != null, "Download button launches installer intent");
                check("content".equals(intent.getData().getScheme()), "Installer uses content URI");
                check(intent.getData().getLastPathSegment().equals(selected.sha256 + ".apk"),
                        "Installer receives the selected APK, not the first item");
                check((intent.getFlags() & Intent.FLAG_GRANT_READ_URI_PERMISSION) != 0,
                        "Installer receives temporary read grant");
                removeMonitor(monitor);
                passed++;
                runOnMainSync(activity::finish);
                Activity reopened = startActivitySync(new Intent(context, MainActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                waitForDownloadButton(reopened);
                runOnMainSync(() -> {
                    RadioButton option = reopened.getWindow().getDecorView().findViewWithTag(selected.id);
                    check(option != null && option.isChecked(), "Selected APK survives reopening");
                });
                passed++;
                runOnMainSync(reopened::finish);
            }
            result.putString("stream", "PASS: " + passed + " on-device checks\n");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("stream", "FAIL after " + passed + " checks: " + error + "\n");
            finish(Activity.RESULT_CANCELED, result);
        }
    }

    private void waitForDownloadButton(Activity activity) throws InterruptedException {
        long deadline = System.currentTimeMillis() + 15000;
        boolean[] ready = {false};
        while (System.currentTimeMillis() < deadline) {
            runOnMainSync(() -> {
                Button found = button(activity.getWindow().getDecorView(), "下载并安装");
                ready[0] = found != null && found.isEnabled();
            });
            if (ready[0]) return;
            Thread.sleep(100);
        }
        throw new AssertionError("Saved endpoint did not load the latest APK");
    }

    private static Button button(View view, String text) {
        if (view instanceof Button && text.contentEquals(((Button) view).getText())) return (Button) view;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int index = 0; index < group.getChildCount(); index++) {
                Button found = button(group.getChildAt(index), text);
                if (found != null) return found;
            }
        }
        return null;
    }

    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
