package app

import "sync"

type broker struct {
	mu          sync.Mutex
	subscribers map[string]map[chan int64]struct{}
}

func newBroker() *broker {
	return &broker{subscribers: make(map[string]map[chan int64]struct{})}
}

func (b *broker) subscribe(familyID string) (<-chan int64, func()) {
	channel := make(chan int64, 1)
	b.mu.Lock()
	if b.subscribers[familyID] == nil {
		b.subscribers[familyID] = make(map[chan int64]struct{})
	}
	b.subscribers[familyID][channel] = struct{}{}
	b.mu.Unlock()
	return channel, func() {
		b.mu.Lock()
		delete(b.subscribers[familyID], channel)
		b.mu.Unlock()
		close(channel)
	}
}

func (b *broker) publish(familyID string, cursor int64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for channel := range b.subscribers[familyID] {
		select {
		case channel <- cursor:
		default:
		}
	}
}
