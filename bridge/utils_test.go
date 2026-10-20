package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFileToBase64(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sample.txt")
	if err := os.WriteFile(path, []byte("hello"), 0o600); err != nil {
		t.Fatalf("写入临时文件失败: %v", err)
	}

	got, err := FileToBase64(path)
	if err != nil {
		t.Fatalf("FileToBase64 失败: %v", err)
	}
	const want = "aGVsbG8="
	if got != want {
		t.Fatalf("base64 结果错误: got %q, want %q", got, want)
	}

	if _, err := FileToBase64(filepath.Join(dir, "missing.txt")); err == nil {
		t.Fatal("读取不存在的文件应当返回错误")
	}
}
