package com.example.seekdbapplication;

import androidx.lifecycle.LiveData;
import androidx.room.Dao;
import androidx.room.Delete;
import androidx.room.Insert;
import androidx.room.Query;
import androidx.room.Update;

import java.util.List;

@Dao
public interface TodoDao {
    @Insert
    void insert(Todo todo);

    @Update
    void update(Todo todo);

    @Delete
    void delete(Todo todo);

    @Query("DELETE FROM todo_table")
    void deleteAll();

    @Query("SELECT * FROM todo_table ORDER BY createdAt DESC")
    LiveData<List<Todo>> getAllTodos();

    @Query("SELECT * FROM todo_table WHERE id = :id")
    LiveData<Todo> getTodoById(int id);
}