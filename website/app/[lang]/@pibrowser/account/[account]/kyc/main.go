// Worker latar belakang: bersih-bersih data dan rekonsiliasi transaksi.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatalf("db: %v", err)
	}
	defer pool.Close()

	go every(ctx, time.Hour, "cleanup", func(c context.Context) error { return cleanup(c, pool) })
	go every(ctx, 30*time.Second, "reconcile", func(c context.Context) error { return reconcile(c, pool) })

	log.Println("worker started")
	<-ctx.Done()
	log.Println("worker stopped")
}

func every(ctx context.Context, d time.Duration, name string, fn func(context.Context) error) {
	t := time.NewTicker(d)
	defer t.Stop()
	for {
		if err := fn(ctx); err != nil && ctx.Err() == nil {
			log.Printf("%s: %v", name, err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Hapus sesi kedaluwarsa dan riwayat browsing > 90 hari.
func cleanup(ctx context.Context, pool *pgxpool.Pool) error {
	tag, err := pool.Exec(ctx,
		`DELETE FROM sessions WHERE expires_at < now() - interval '7 days'
		   OR revoked_at < now() - interval '7 days'`)
	if err != nil {
		return err
	}
	tag2, err := pool.Exec(ctx,
		`DELETE FROM browse_history WHERE visited_at < now() - interval '90 days'`)
	if err != nil {
		return err
	}
	log.Printf("cleanup: %d sesi, %d riwayat dihapus", tag.RowsAffected(), tag2.RowsAffected())
	return nil
}

type chainResp struct {
	Status string `json:"status"` // "confirmed" | "failed" | "pending"
}

// Cek transaksi pending ke API blockchain. CHAIN_API_URL harus mengembalikan
// JSON {"status": "..."} pada GET {CHAIN_API_URL}/{tx_hash}. Sesuaikan dengan API asli Anda.
func reconcile(ctx context.Context, pool *pgxpool.Pool) error {
	base := os.Getenv("CHAIN_API_URL")
	if base == "" {
		return nil
	}
	rows, err := pool.Query(ctx,
		`SELECT id, tx_hash FROM transactions
		  WHERE status = 'pending' AND created_at < now() - interval '30 seconds'
		  ORDER BY created_at LIMIT 50`)
	if err != nil {
		return err
	}
	type item struct{ id, hash string }
	var items []item
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.id, &it.hash); err != nil {
			rows.Close()
			return err
		}
		items = append(items, it)
	}
	rows.Close()

	client := &http.Client{Timeout: 10 * time.Second}
	for _, it := range items {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s/%s", base, it.hash), nil)
		resp, err := client.Do(req)
		if err != nil {
			log.Printf("chain %s: %v", it.hash, err)
			continue
		}
		var cr chainResp
		err = json.NewDecoder(resp.Body).Decode(&cr)
		resp.Body.Close()
		if err != nil || (cr.Status != "confirmed" && cr.Status != "failed") {
			continue
		}
		_, err = pool.Exec(ctx,
			`UPDATE transactions SET status = $2,
			        confirmed_at = CASE WHEN $2 = 'confirmed' THEN now() END
			  WHERE id = $1 AND status = 'pending'`, it.id, cr.Status)
		if err != nil {
			log.Printf("update %s: %v", it.hash, err)
		}
	}
	return nil
}
