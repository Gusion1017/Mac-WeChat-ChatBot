package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/mgutz/ansi"
	"github.com/rs/zerolog"
	"gopkg.in/natefinch/lumberjack.v2"
)

// logFilePath 由 -log_file 指定。App 会传 ~/Library/Logs/WeChatAI/bridge/macos.log
// （必须在 app bundle 之外）：旧实现固定写 ./log/macos.log，而 bridge 的 cwd 在
// bundle 内，落盘会破坏 ad-hoc 签名，导致助手下次启动被 macOS 以
// Launch Constraint Violation 杀掉。
var logFilePath = "./log/macos.log"

type LoggerInfo struct {
	logger zerolog.Logger
}

type QQLoggerInfo struct {
	logger zerolog.Logger
}

var (
	logLevel string
)

// Logger instance
var Logger = new(LoggerInfo)
var QQLogger = new(QQLoggerInfo)

// initLogger init logger
func initLogger() {
	if logFilePath == "" {
		logFilePath = "./log/macos.log"
	}
	if err := os.MkdirAll(filepath.Dir(logFilePath), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "创建日志目录失败:", err)
	}
	fileWriter := &lumberjack.Logger{
		Filename:   logFilePath,
		MaxSize:    100,
		MaxBackups: 10,
		MaxAge:     30,
		Compress:   false,
	}

	stdoutWriter := zerolog.ConsoleWriter{
		Out:         os.Stdout,
		TimeFormat:  "2006-01-02 15:04:05",
		FormatLevel: Logger.ColorFormatLevel,
	}

	Logger.logger = zerolog.New(zerolog.MultiLevelWriter(fileWriter, stdoutWriter)).With().
		Timestamp().
		Logger()
	QQLogger.logger = Logger.logger

	log.SetOutput(Logger.logger)
	log.SetFlags(0)
	// set log level
	switch strings.ToLower(logLevel) {
	case "debug":
		zerolog.SetGlobalLevel(zerolog.DebugLevel)
	case "info":
		zerolog.SetGlobalLevel(zerolog.InfoLevel)
	case "warn":
		zerolog.SetGlobalLevel(zerolog.WarnLevel)
	case "error":
		zerolog.SetGlobalLevel(zerolog.ErrorLevel)
	default:
		zerolog.SetGlobalLevel(zerolog.InfoLevel)
	}
}

func getCallerFile() string {
	_, filename, line, _ := runtime.Caller(2)
	return fmt.Sprintf("%s:%d", filename, line)
}

func DebugCtx(ctx context.Context, msg string, fields ...interface{}) {
	callerFile := getCallerFile()
	Logger.logger.Debug().Fields(fields).Msg(callerFile + " " + msg)
}

// InfoCtx info log
func InfoCtx(ctx context.Context, msg string, fields ...interface{}) {
	callerFile := getCallerFile()
	Logger.logger.Info().Fields(fields).Msg(callerFile + " " + msg)
}

// WarnCtx log
func WarnCtx(ctx context.Context, msg string, fields ...interface{}) {
	callerFile := getCallerFile()
	Logger.logger.Warn().Fields(fields).Msg(callerFile + " " + msg)
}

// ErrorCtx error log
func ErrorCtx(ctx context.Context, msg string, fields ...interface{}) {
	callerFile := getCallerFile()
	Logger.logger.Error().Fields(fields).Msg(callerFile + " " + msg)
}

// FatalCtx fatal log
func FatalCtx(ctx context.Context, msg string, fields ...interface{}) {
	callerFile := getCallerFile()
	Logger.logger.Fatal().Fields(fields).Msg(callerFile + " " + msg)
}

func Debug(msg string, fields ...interface{}) {
	callerFile := getCallerFile()
	Logger.logger.Debug().Fields(fields).Msg(callerFile + " " + msg)
}

// Info info log
func Info(msg string, fields ...interface{}) {
	callerFile := getCallerFile()
	Logger.logger.Info().Fields(fields).Msg(callerFile + " " + msg)
}

// Warn log
func Warn(msg string, fields ...interface{}) {
	callerFile := getCallerFile()
	Logger.logger.Warn().Fields(fields).Msg(callerFile + " " + msg)
}

// Error error log
func Error(msg string, fields ...interface{}) {
	callerFile := getCallerFile()
	Logger.logger.Error().Fields(fields).Msg(callerFile + " " + msg)
}

// Fatal fatal log
func Fatal(msg string, fields ...interface{}) {
	callerFile := getCallerFile()
	Logger.logger.Fatal().Fields(fields).Msg(callerFile + " " + msg)
}

func (l *LoggerInfo) ColorFormatLevel(i interface{}) string {
	level := strings.ToUpper(fmt.Sprintf("%v", i))
	switch level {
	case "DEBUG":
		return ansi.Color(fmt.Sprintf("| %-5s |", level), "cyan")
	case "INFO":
		return ansi.Color(fmt.Sprintf("| %-5s |", level), "green")
	case "WARN":
		return ansi.Color(fmt.Sprintf("| %-5s |", level), "yellow")
	case "ERROR":
		return ansi.Color(fmt.Sprintf("| %-5s |", level), "red")
	case "FATAL":
		return ansi.Color(fmt.Sprintf("| %-5s |", level), "magenta")
	case "PANIC":
		return ansi.Color(fmt.Sprintf("| %-5s |", level), "magenta+bh")
	default:
		return ansi.Color(fmt.Sprintf("| %-5s |", "STD"), "white")
	}
}
