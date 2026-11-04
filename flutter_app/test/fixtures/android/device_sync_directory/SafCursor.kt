package android.database

interface Cursor : java.io.Closeable {
    fun moveToNext(): Boolean
    fun getString(column: Int): String
    fun getLong(column: Int): Long
    fun getInt(column: Int): Int
}
