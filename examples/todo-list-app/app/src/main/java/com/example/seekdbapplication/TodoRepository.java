package com.example.seekdbapplication;

import android.app.Application;

import androidx.lifecycle.LiveData;

import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class TodoRepository {
    private TodoDao todoDao;
    private LiveData<List<Todo>> allTodos;
    private ExecutorService executorService;

    public TodoRepository(Application application) {
        TodoDatabase database = TodoDatabase.getDatabase(application);
        todoDao = database.todoDao();
        allTodos = todoDao.getAllTodos();
        executorService = Executors.newFixedThreadPool(4);
    }

    public void insert(Todo todo) {
        executorService.execute(() -> todoDao.insert(todo));
    }

    public void update(Todo todo) {
        executorService.execute(() -> todoDao.update(todo));
    }

    public void delete(Todo todo) {
        executorService.execute(() -> todoDao.delete(todo));
    }

    public void deleteAll() {
        executorService.execute(() -> todoDao.deleteAll());
    }

    public LiveData<List<Todo>> getAllTodos() {
        return allTodos;
    }
}
