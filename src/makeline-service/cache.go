package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
)

// Cache key prefixes. The pending-orders list and individual orders are cached
// separately so reads can be served without hitting the database on every call.
const (
	pendingOrdersCacheKey = "makeline:orders:pending"
	orderCacheKeyPrefix   = "makeline:order:"
)

// CachedOrderRepo is an OrderRepo decorator that adds a Redis read cache in
// front of an underlying repository (MongoDB/DocumentDB or CosmosDB). Reads are
// served from Redis when available and fall back to the database on a miss.
// Writes go through to the database and then invalidate the affected cache
// entries so subsequent reads stay consistent.
type CachedOrderRepo struct {
	inner  OrderRepo
	client *redis.Client
	ttl    time.Duration
}

// NewCachedOrderRepo wraps the given repo with a Redis-backed cache. It returns
// an error if it cannot connect to Redis so callers can decide whether to fall
// back to the uncached repository.
func NewCachedOrderRepo(inner OrderRepo, addr string, password string, ttl time.Duration) (*CachedOrderRepo, error) {
	client := redis.NewClient(&redis.Options{
		Addr:     addr,
		Password: password,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := client.Ping(ctx).Err(); err != nil {
		_ = client.Close()
		return nil, err
	}

	log.Printf("Redis cache connected at %s (ttl=%s)", addr, ttl)
	return &CachedOrderRepo{inner: inner, client: client, ttl: ttl}, nil
}

// NewCachedOrderRepoIfEnabled wraps repo with a Redis cache when REDIS_HOST is
// set. When Redis is not configured or unreachable, it logs and returns the
// original repo so the service keeps working without a cache.
func NewCachedOrderRepoIfEnabled(repo OrderRepo) OrderRepo {
	host := os.Getenv("REDIS_HOST")
	if host == "" {
		log.Printf("REDIS_HOST not set; running without cache")
		return repo
	}

	port := os.Getenv("REDIS_PORT")
	if port == "" {
		port = "6379"
	}

	ttl := 10 * time.Second
	if v := os.Getenv("REDIS_CACHE_TTL_SECONDS"); v != "" {
		if seconds, err := strconv.Atoi(v); err == nil && seconds > 0 {
			ttl = time.Duration(seconds) * time.Second
		} else {
			log.Printf("invalid REDIS_CACHE_TTL_SECONDS %q, using default %s", v, ttl)
		}
	}

	cached, err := NewCachedOrderRepo(repo, host+":"+port, os.Getenv("REDIS_PASSWORD"), ttl)
	if err != nil {
		log.Printf("failed to connect to Redis cache at %s:%s: %s. Continuing without cache.", host, port, err)
		return repo
	}
	return cached
}

func (r *CachedOrderRepo) GetPendingOrders() ([]Order, error) {
	ctx := context.Background()

	cached, err := r.client.Get(ctx, pendingOrdersCacheKey).Bytes()
	if err == nil {
		var orders []Order
		if err := json.Unmarshal(cached, &orders); err == nil {
			return orders, nil
		}
		log.Printf("failed to unmarshal cached pending orders, falling back to database: %s", err)
	} else if !errors.Is(err, redis.Nil) {
		log.Printf("redis GET pending orders failed, falling back to database: %s", err)
	}

	orders, err := r.inner.GetPendingOrders()
	if err != nil {
		return nil, err
	}

	if data, err := json.Marshal(orders); err == nil {
		if err := r.client.Set(ctx, pendingOrdersCacheKey, data, r.ttl).Err(); err != nil {
			log.Printf("failed to cache pending orders: %s", err)
		}
	}

	return orders, nil
}

func (r *CachedOrderRepo) GetOrder(id string) (Order, error) {
	ctx := context.Background()
	key := orderCacheKeyPrefix + id

	cached, err := r.client.Get(ctx, key).Bytes()
	if err == nil {
		var order Order
		if err := json.Unmarshal(cached, &order); err == nil {
			return order, nil
		}
		log.Printf("failed to unmarshal cached order %s, falling back to database: %s", id, err)
	} else if !errors.Is(err, redis.Nil) {
		log.Printf("redis GET order %s failed, falling back to database: %s", id, err)
	}

	order, err := r.inner.GetOrder(id)
	if err != nil {
		return order, err
	}

	if data, err := json.Marshal(order); err == nil {
		if err := r.client.Set(ctx, key, data, r.ttl).Err(); err != nil {
			log.Printf("failed to cache order %s: %s", id, err)
		}
	}

	return order, nil
}

func (r *CachedOrderRepo) InsertOrders(orders []Order) error {
	if err := r.inner.InsertOrders(orders); err != nil {
		return err
	}
	// New orders are pending, so the cached pending list is now stale.
	r.invalidatePendingOrders()
	return nil
}

func (r *CachedOrderRepo) UpdateOrder(order Order) error {
	if err := r.inner.UpdateOrder(order); err != nil {
		return err
	}
	// The order changed status, so both the pending list and the individual
	// order entry are now stale.
	r.invalidatePendingOrders()
	r.invalidateOrder(order.OrderID)
	return nil
}

func (r *CachedOrderRepo) invalidatePendingOrders() {
	ctx := context.Background()
	if err := r.client.Del(ctx, pendingOrdersCacheKey).Err(); err != nil {
		log.Printf("failed to invalidate pending orders cache: %s", err)
	}
}

func (r *CachedOrderRepo) invalidateOrder(id string) {
	ctx := context.Background()
	if err := r.client.Del(ctx, orderCacheKeyPrefix+id).Err(); err != nil {
		log.Printf("failed to invalidate order %s cache: %s", id, err)
	}
}
