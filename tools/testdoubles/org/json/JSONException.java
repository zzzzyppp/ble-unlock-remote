package org.json;

/** 测试用替身：对应 android.jar 中同为占位实现的 JSONException。 */
public class JSONException extends Exception {
    public JSONException(String message) {
        super(message);
    }
}
