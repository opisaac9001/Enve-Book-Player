package com.enve.woof;

import android.content.Context;
import com.chaquo.python.PyObject;
import com.chaquo.python.Python;
import com.chaquo.python.android.AndroidPlatform;
import java.util.function.BooleanSupplier;

public final class WoofRuntime implements AutoCloseable {
    private final PyObject renderer;

    public WoofRuntime(Context context, String weights) {
        synchronized (Python.class) {
            if (!Python.isStarted()) {
                Python.start(new AndroidPlatform(context));
            }
        }
        try (PyObject module = Python.getInstance().getModule("enve_woof")) {
            renderer = module.callAttr("Renderer", weights);
        }
    }

    public byte[] synthesize(String text, String voice, BooleanSupplier isCurrent) {
        try (PyObject result = renderer.callAttr("synthesize", text, voice, isCurrent)) {
            return result.toJava(byte[].class);
        }
    }

    @Override
    public void close() {
        renderer.close();
    }
}
