package com.example.seekdbapplication;

import android.content.Context;

import androidx.room.Database;
import androidx.room.Room;
import androidx.room.RoomDatabase;

import com.oceanbase.seekdb.android.compat.SeekdbCompat;

/**
 * Room on SeekDB: {@link SeekdbCompat#factory()} wires the embedded engine.
 * Invalidation uses
 * native {@code CREATE TRIGGER} on {@code room_table_modification_log} (same
 * idea as sqlite-android);
 * no extra {@code Application} hook is required. Ship a matching
 * {@code libseekdb.so} (see
 * seekdb-android {@code jniLibs} / local build).
 */
@Database(entities = { Todo.class }, version = 1, exportSchema = false)
public abstract class TodoDatabase extends RoomDatabase {
    private static volatile TodoDatabase INSTANCE;

    public abstract TodoDao todoDao();

    public static TodoDatabase getDatabase(final Context context) {
        if (INSTANCE == null) {
            synchronized (TodoDatabase.class) {
                if (INSTANCE == null) {
                    INSTANCE = Room.databaseBuilder(
                            context.getApplicationContext(),
                            TodoDatabase.class,
                            "todo_database")
                            .openHelperFactory(SeekdbCompat.factory())
                            .build();
                }
            }
        }
        return INSTANCE;
    }
}
