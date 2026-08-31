package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"solutions.bytesized/uneton/platform/backend/internal/historyimport"
	"solutions.bytesized/uneton/platform/backend/internal/store"
)

func main() {
	var (
		csvPath      = flag.String("csv", "", "sleep-history CSV export to import")
		databasePath = flag.String("database", "platform/backend/var/uneton.sqlite", "authoritative SQLite database")
		timezone     = flag.String("timezone", "", "IANA timezone used by timestamps without an offset")
		familyID     = flag.String("family-id", "", "existing destination family UUID")
		childID      = flag.String("child-id", "", "existing destination child UUID")
		authorID     = flag.String("author-id", "", "existing caregiver UUID attributed as author")
	)
	flag.Parse()
	if *csvPath == "" || *timezone == "" {
		flag.Usage()
		exit("csv and timezone are required")
	}
	location, err := time.LoadLocation(*timezone)
	if err != nil {
		exit("load timezone: %v", err)
	}
	file, err := os.Open(*csvPath)
	if err != nil {
		exit("open CSV: %v", err)
	}
	parsed, err := historyimport.Parse(file, location)
	closeErr := file.Close()
	if err != nil {
		exit("parse CSV: %v", err)
	}
	if closeErr != nil {
		exit("close CSV: %v", closeErr)
	}
	if *databasePath != ":memory:" {
		if err := os.MkdirAll(filepath.Dir(*databasePath), 0o750); err != nil {
			exit("create database directory: %v", err)
		}
	}
	database, err := store.Open(*databasePath)
	if err != nil {
		exit("open database: %v", err)
	}
	defer func() {
		if closeErr := database.Close(); closeErr != nil {
			exit("close database: %v", closeErr)
		}
	}()
	options := historyimport.ImportOptions{FamilyID: *familyID, ChildID: *childID, AuthorID: *authorID}
	result, err := historyimport.Import(context.Background(), database, parsed, options)
	if err != nil {
		exit("import: %v", err)
	}
	fmt.Printf("history import complete: parsed=%d inserted=%d merged=%d ignored=%d\n", result.Parsed, result.Inserted, result.Merged, result.Ignored)
}

func exit(format string, arguments ...any) {
	fmt.Fprintf(os.Stderr, "import-history: "+format+"\n", arguments...)
	os.Exit(1)
}
