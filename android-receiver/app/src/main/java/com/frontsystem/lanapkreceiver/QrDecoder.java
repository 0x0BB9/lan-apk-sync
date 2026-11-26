package com.frontsystem.lanapkreceiver;

import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.LuminanceSource;
import com.google.zxing.NotFoundException;
import com.google.zxing.PlanarYUVLuminanceSource;
import com.google.zxing.RGBLuminanceSource;
import com.google.zxing.ReaderException;
import com.google.zxing.common.HybridBinarizer;
import com.google.zxing.qrcode.QRCodeReader;
import java.util.EnumMap;
import java.util.Map;

final class QrDecoder {
    private QrDecoder() {}

    static String frame(byte[] data, int width, int height) throws NotFoundException {
        return decode(new PlanarYUVLuminanceSource(data, width, height, 0, 0, width, height, false));
    }

    static String image(int[] pixels, int width, int height) throws NotFoundException {
        return decode(new RGBLuminanceSource(width, height, pixels));
    }

    private static String decode(LuminanceSource source) throws NotFoundException {
        QRCodeReader reader = new QRCodeReader();
        Map<DecodeHintType, Object> hints = new EnumMap<>(DecodeHintType.class);
        hints.put(DecodeHintType.TRY_HARDER, Boolean.TRUE);
        try {
            return reader.decode(new BinaryBitmap(new HybridBinarizer(source)), hints).getText();
        } catch (ReaderException first) {
            try {
                return reader.decode(new BinaryBitmap(new HybridBinarizer(source.invert())), hints).getText();
            } catch (ReaderException ignored) { throw NotFoundException.getNotFoundInstance(); }
        } finally { reader.reset(); }
    }
}
