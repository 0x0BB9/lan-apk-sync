package com.frontsystem.lanapkreceiver;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.hardware.Camera;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.google.zxing.NotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/** Bundled ZXing + platform camera; no browser, Google services or downloaded model. */
@SuppressWarnings("deprecation")
@android.annotation.SuppressLint("SetTextI18n") // This internal tool has a Chinese-only UI.
public final class ScanActivity extends Activity implements SurfaceHolder.Callback {
    static final String RESULT_URL = "scanned_url";
    private static final int PICK_IMAGE = 21;
    private final ExecutorService decoder = Executors.newSingleThreadExecutor();
    private final AtomicBoolean decoding = new AtomicBoolean();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private SurfaceView preview;
    private TextView hint;
    private Camera camera;
    private boolean active;
    private boolean finished;
    private boolean torch;
    private long lastFrame;
    private int previewRotation;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.BLACK);
        root.setPadding(24, 48, 24, 24);
        root.setFitsSystemWindows(true);
        hint = new TextView(this);
        hint.setText("对准 Mac 工具显示的二维码\n识别在手机本地完成，不会打开浏览器");
        hint.setTextColor(Color.WHITE);
        hint.setTextSize(18);
        hint.setGravity(Gravity.CENTER);
        hint.setPadding(0, 20, 0, 24);
        root.addView(hint, new LinearLayout.LayoutParams(-1, -2));
        FrameLayout frame = new FrameLayout(this);
        preview = new SurfaceView(this);
        preview.getHolder().addCallback(this);
        frame.addView(preview, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));
        root.addView(frame, new LinearLayout.LayoutParams(-1, 0, 1));
        Button light = new Button(this);
        light.setText("打开 / 关闭补光");
        light.setOnClickListener(view -> toggleTorch());
        root.addView(light);
        Button image = new Button(this);
        image.setText("从二维码图片识别");
        image.setOnClickListener(view -> {
            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("image/*")
                    .addCategory(Intent.CATEGORY_OPENABLE);
            try { startActivityForResult(intent, PICK_IMAGE); }
            catch (android.content.ActivityNotFoundException exception) { hint.setText("系统没有图片选择器，请使用相机扫码。"); }
        });
        root.addView(image);
        Button back = new Button(this);
        back.setText("取消");
        back.setOnClickListener(view -> finish());
        root.addView(back);
        setContentView(root);
    }

    @Override protected void onResume() {
        super.onResume();
        active = true;
        if (preview.getHolder().getSurface().isValid()) startCamera();
    }

    @Override protected void onPause() {
        active = false;
        releaseCamera();
        super.onPause();
    }

    @Override public void surfaceCreated(SurfaceHolder holder) { startCamera(); }
    @Override public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) { fitPreview(); }
    @Override public void surfaceDestroyed(SurfaceHolder holder) { releaseCamera(); }

    private void startCamera() {
        if (!active || camera != null || finished || !preview.getHolder().getSurface().isValid()) return;
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            hint.setText("相机权限未开启，请返回使用手动输入。");
            return;
        }
        try {
            int id = -1;
            Camera.CameraInfo info = new Camera.CameraInfo();
            for (int index = 0; index < Camera.getNumberOfCameras(); index++) {
                Camera.getCameraInfo(index, info);
                if (info.facing == Camera.CameraInfo.CAMERA_FACING_BACK) { id = index; break; }
            }
            if (id < 0) throw new IOException("No rear camera");
            Camera.getCameraInfo(id, info);
            camera = Camera.open(id);
            Camera.Parameters params = camera.getParameters();
            Camera.Size selected = null;
            for (Camera.Size size : params.getSupportedPreviewSizes()) {
                if (size.width <= 1280 && size.height <= 1280
                        && (selected == null || size.width * size.height > selected.width * selected.height)) selected = size;
            }
            if (selected != null) params.setPreviewSize(selected.width, selected.height);
            params.setPreviewFormat(android.graphics.ImageFormat.NV21);
            List<String> modes = params.getSupportedFocusModes();
            if (modes != null && modes.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE)) {
                params.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE);
            } else if (modes != null && modes.contains(Camera.Parameters.FOCUS_MODE_AUTO)) {
                params.setFocusMode(Camera.Parameters.FOCUS_MODE_AUTO);
            }
            camera.setParameters(params);
            int rotation = getWindowManager().getDefaultDisplay().getRotation();
            int degrees = rotation == Surface.ROTATION_90 ? 90 : rotation == Surface.ROTATION_180 ? 180
                    : rotation == Surface.ROTATION_270 ? 270 : 0;
            previewRotation = (info.orientation - degrees + 360) % 360;
            camera.setDisplayOrientation(previewRotation);
            camera.setPreviewDisplay(preview.getHolder());
            camera.setPreviewCallback((bytes, source) -> {
                long now = System.nanoTime();
                if (!active || finished || now - lastFrame < 250_000_000 || !decoding.compareAndSet(false, true)) return;
                lastFrame = now;
                Camera.Size size = source.getParameters().getPreviewSize();
                byte[] copy = bytes.clone();
                decoder.execute(() -> {
                    try { result(QrDecoder.frame(copy, size.width, size.height)); }
                    catch (NotFoundException ignored) { /* Try the next frame. */ }
                    finally { decoding.set(false); }
                });
            });
            camera.startPreview();
            fitPreview();
            focus();
        } catch (IOException | RuntimeException exception) {
            releaseCamera();
            hint.setText("无法打开后置相机。请检查权限，或从二维码图片识别 / 返回手动输入。");
        }
    }

    private void fitPreview() {
        if (camera == null || preview.getParent() == null) return;
        View parent = (View) preview.getParent();
        if (parent.getWidth() == 0 || parent.getHeight() == 0) { preview.post(this::fitPreview); return; }
        Camera.Size size = camera.getParameters().getPreviewSize();
        float ratio = previewRotation % 180 == 0 ? (float) size.width / size.height
                : (float) size.height / size.width;
        int width = parent.getWidth();
        int height = Math.round(width / ratio);
        if (height > parent.getHeight()) { height = parent.getHeight(); width = Math.round(height * ratio); }
        preview.setLayoutParams(new FrameLayout.LayoutParams(width, height, Gravity.CENTER));
    }

    private void focus() {
        if (camera == null || !active) return;
        try {
            if (Camera.Parameters.FOCUS_MODE_AUTO.equals(camera.getParameters().getFocusMode())) {
                camera.autoFocus((success, source) -> { });
                handler.postDelayed(this::focus, 1800);
            }
        } catch (RuntimeException ignored) { /* Device may be closing the camera. */ }
    }

    private void toggleTorch() {
        if (camera == null) return;
        try {
            Camera.Parameters params = camera.getParameters();
            List<String> modes = params.getSupportedFlashModes();
            if (modes == null || !modes.contains(Camera.Parameters.FLASH_MODE_TORCH)) {
                hint.setText("这台设备不支持扫码补光。");
                return;
            }
            torch = !torch;
            params.setFlashMode(torch ? Camera.Parameters.FLASH_MODE_TORCH : Camera.Parameters.FLASH_MODE_OFF);
            camera.setParameters(params);
        } catch (RuntimeException ignored) { hint.setText("无法切换补光，请调整环境光线。"); }
    }

    private void result(String value) {
        handler.post(() -> {
            if (isDestroyed() || finished) return;
            try { ShareEndpoint.parse(value); }
            catch (IllegalArgumentException exception) {
                hint.setText("不是有效的 Mac 局域网分享码，请重新对准二维码。");
                return;
            }
            finished = true;
            setResult(RESULT_OK, new Intent().putExtra(RESULT_URL, value));
            finish();
        });
    }

    @Override protected void onActivityResult(int request, int resultCode, Intent data) {
        super.onActivityResult(request, resultCode, data);
        if (request != PICK_IMAGE || resultCode != RESULT_OK || data == null || data.getData() == null) return;
        android.net.Uri uri = data.getData();
        hint.setText("正在本地识别图片…");
        decoder.execute(() -> {
            Bitmap bitmap = null;
            try {
                BitmapFactory.Options options = new BitmapFactory.Options();
                options.inJustDecodeBounds = true;
                try (InputStream input = getContentResolver().openInputStream(uri)) {
                    BitmapFactory.decodeStream(input, null, options);
                }
                if (options.outWidth <= 0 || options.outHeight <= 0) throw new IOException("Invalid image");
                options.inSampleSize = 1;
                while (options.outWidth / options.inSampleSize > 2048
                        || options.outHeight / options.inSampleSize > 2048) options.inSampleSize *= 2;
                options.inJustDecodeBounds = false;
                try (InputStream input = getContentResolver().openInputStream(uri)) {
                    bitmap = BitmapFactory.decodeStream(input, null, options);
                }
                if (bitmap == null) throw new IOException("Invalid image");
                int width = bitmap.getWidth();
                int height = bitmap.getHeight();
                int[] pixels = new int[width * height];
                bitmap.getPixels(pixels, 0, width, 0, 0, width, height);
                result(QrDecoder.image(pixels, width, height));
            } catch (IOException | NotFoundException | RuntimeException exception) {
                handler.post(() -> { if (!isDestroyed()) hint.setText("未识别到有效二维码，请重选清晰的原图，或继续相机扫码。"); });
            } finally { if (bitmap != null) bitmap.recycle(); }
        });
    }

    private void releaseCamera() {
        handler.removeCallbacksAndMessages(null);
        torch = false;
        if (camera != null) {
            try { camera.setPreviewCallback(null); camera.stopPreview(); }
            catch (RuntimeException ignored) { /* Already stopped by the system. */ }
            camera.release();
            camera = null;
        }
    }

    @Override protected void onDestroy() {
        releaseCamera();
        decoder.shutdownNow();
        super.onDestroy();
    }
}
