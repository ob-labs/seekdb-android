package com.example.seekdbapplication;

import android.os.Bundle;
import android.text.TextUtils;
import android.view.LayoutInflater;
import android.view.View;
import android.widget.EditText;
import android.widget.TextView;
import android.widget.Toast;

import androidx.activity.EdgeToEdge;
import androidx.appcompat.app.AlertDialog;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.lifecycle.ViewModelProvider;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import com.google.android.material.floatingactionbutton.FloatingActionButton;

public class MainActivity extends AppCompatActivity implements TodoAdapter.OnTodoClickListener {

    private TodoViewModel todoViewModel;
    private TodoAdapter adapter;
    private TextView textViewEmpty;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        EdgeToEdge.enable(this);
        setContentView(R.layout.activity_main);
        ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.main), (v, insets) -> {
            Insets systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars());
            v.setPadding(systemBars.left, systemBars.top, systemBars.right, systemBars.bottom);
            return insets;
        });

        // 初始化视图
        RecyclerView recyclerView = findViewById(R.id.recyclerView);
        textViewEmpty = findViewById(R.id.textViewEmpty);
        FloatingActionButton fabAdd = findViewById(R.id.fabAdd);

        // 设置 RecyclerView
        adapter = new TodoAdapter();
        adapter.setOnTodoClickListener(this);
        recyclerView.setLayoutManager(new LinearLayoutManager(this));
        recyclerView.setAdapter(adapter);

        // 初始化 ViewModel
        todoViewModel = new ViewModelProvider.AndroidViewModelFactory(getApplication())
                .create(TodoViewModel.class);

        // 观察数据变化
        todoViewModel.getAllTodos().observe(this, todos -> {
            adapter.setTodos(todos);
            textViewEmpty.setVisibility(todos == null || todos.isEmpty() ? View.VISIBLE : View.GONE);
        });

        // 添加按钮点击事件
        fabAdd.setOnClickListener(v -> showAddTodoDialog());
    }

    private void showAddTodoDialog() {
        AlertDialog.Builder builder = new AlertDialog.Builder(this);
        View dialogView = LayoutInflater.from(this).inflate(R.layout.dialog_add_todo, null);
        EditText editTextTitle = dialogView.findViewById(R.id.editTextTitle);
        EditText editTextDescription = dialogView.findViewById(R.id.editTextDescription);

        builder.setView(dialogView);
        builder.setPositiveButton("添加", (dialog, which) -> {
            String title = editTextTitle.getText().toString().trim();
            String description = editTextDescription.getText().toString().trim();

            if (TextUtils.isEmpty(title)) {
                Toast.makeText(MainActivity.this, "请输入标题", Toast.LENGTH_SHORT).show();
                return;
            }

            Todo todo = new Todo(title, description);
            todoViewModel.insert(todo);
            Toast.makeText(MainActivity.this, "添加成功", Toast.LENGTH_SHORT).show();
        });
        builder.setNegativeButton("取消", null);
        builder.show();
    }

    @Override
    public void onTodoClick(Todo todo) {
        showEditTodoDialog(todo);
    }

    @Override
    public void onTodoDelete(Todo todo) {
        new AlertDialog.Builder(this)
                .setTitle("删除任务")
                .setMessage("确定要删除这个任务吗？")
                .setPositiveButton("删除", (dialog, which) -> {
                    todoViewModel.delete(todo);
                    Toast.makeText(MainActivity.this, "删除成功", Toast.LENGTH_SHORT).show();
                })
                .setNegativeButton("取消", null)
                .show();
    }

    @Override
    public void onTodoStatusChanged(Todo todo, boolean isCompleted) {
        todoViewModel.update(todo);
        String message = isCompleted ? "已完成" : "未完成";
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
    }

    private void showEditTodoDialog(Todo todo) {
        AlertDialog.Builder builder = new AlertDialog.Builder(this);
        View dialogView = LayoutInflater.from(this).inflate(R.layout.dialog_add_todo, null);
        EditText editTextTitle = dialogView.findViewById(R.id.editTextTitle);
        EditText editTextDescription = dialogView.findViewById(R.id.editTextDescription);

        editTextTitle.setText(todo.getTitle());
        editTextDescription.setText(todo.getDescription());

        builder.setTitle("编辑任务");
        builder.setView(dialogView);
        builder.setPositiveButton("保存", (dialog, which) -> {
            String title = editTextTitle.getText().toString().trim();
            String description = editTextDescription.getText().toString().trim();

            if (TextUtils.isEmpty(title)) {
                Toast.makeText(MainActivity.this, "请输入标题", Toast.LENGTH_SHORT).show();
                return;
            }

            todo.setTitle(title);
            todo.setDescription(description);
            todoViewModel.update(todo);
            Toast.makeText(MainActivity.this, "更新成功", Toast.LENGTH_SHORT).show();
        });
        builder.setNegativeButton("取消", null);
        builder.show();
    }
}