package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"solutions.bytesized/uneton/platform/backend/internal/store"
	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
)

type seedFile struct {
	Curves []seedCurve `json:"curves"`
}

type seedCurve struct {
	Reference string  `json:"reference"`
	Metric    string  `json:"metric"`
	Points    [][]int `json:"points"` // Monthly values ordered -2SD, -1SD, 0SD, +1SD, +2SD.
}

func main() {
	var (
		databasePath = flag.String("database", "platform/backend/var/uneton.sqlite", "authoritative SQLite database")
		sourcePath   = flag.String("source", "tmp/growth-reference.json", "private growth-reference seed JSON")
	)
	flag.Parse()

	data, err := os.ReadFile(*sourcePath)
	if err != nil {
		exit("read seed file: %v", err)
	}
	var input seedFile
	if err := json.Unmarshal(data, &input); err != nil {
		exit("decode seed file: %v", err)
	}
	if len(input.Curves) == 0 {
		exit("seed file contains no curves")
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
		if err := database.Close(); err != nil {
			exit("close database: %v", err)
		}
	}()

	ctx := context.Background()
	tx, err := database.DB.BeginTx(ctx, nil)
	if err != nil {
		exit("begin transaction: %v", err)
	}
	defer func() { _ = tx.Rollback() }()
	queries := database.Queries.WithTx(tx)
	if err := queries.DeleteGrowthReferencePoints(ctx); err != nil {
		exit("clear existing reference points: %v", err)
	}
	inserted := 0
	for _, curve := range input.Curves {
		if (curve.Reference != "girl" && curve.Reference != "boy") || (curve.Metric != "height" && curve.Metric != "weight") {
			exit("invalid curve %q/%q", curve.Reference, curve.Metric)
		}
		for month, values := range curve.Points {
			if len(values) != 5 {
				exit("%q/%q month %d has %d values; expected -2SD through +2SD", curve.Reference, curve.Metric, month, len(values))
			}
			for index, value := range values {
				if value <= 0 {
					exit("%q/%q month %d has invalid value", curve.Reference, curve.Metric, month)
				}
				if err := queries.CreateGrowthReferencePoint(ctx, storedb.CreateGrowthReferencePointParams{
					Reference: curve.Reference,
					Metric:    curve.Metric,
					AgeMonths: int64(month),
					Sd:        int64(index - 2),
					Value:     int64(value),
				}); err != nil {
					exit("insert %q/%q month %d: %v", curve.Reference, curve.Metric, month, err)
				}
				inserted++
			}
		}
	}
	if err := tx.Commit(); err != nil {
		exit("commit seed: %v", err)
	}
	fmt.Printf("growth reference seed complete: points=%d source=%s\n", inserted, *sourcePath)
}

func exit(format string, arguments ...any) {
	fmt.Fprintf(os.Stderr, "seed-growth-reference: "+format+"\n", arguments...)
	os.Exit(1)
}
