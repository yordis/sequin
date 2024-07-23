package api

import (
	"log"

	"github.com/sequinstream/sequin/cli/context"
)

type ObserveChannel struct {
	BaseChannel
}

func NewObserveChannel(ctx *context.Context) (*ObserveChannel, error) {
	baseChannel, err := NewBaseChannel(ctx, "observe", &SilentLogger{})
	if err != nil {
		return nil, err
	}

	oc := &ObserveChannel{
		BaseChannel: *baseChannel,
	}

	return oc, nil
}

func (oc *ObserveChannel) Connect() error {
	return oc.BaseChannel.Connect("observe")
}

func (oc *ObserveChannel) OnStreamCreated(handler func(Stream)) {
	oc.channel.On("stream:created", func(payload any) {
		var stream Stream
		if err := parsePayload(payload, &stream); err != nil {
			log.Printf("Error parsing stream:created payload: %v", err)
			return
		}
		handler(stream)
	})
}

func (oc *ObserveChannel) OnStreamUpdated(handler func(Stream)) {
	oc.channel.On("stream:updated", func(payload any) {
		var stream Stream
		if err := parsePayload(payload, &stream); err != nil {
			log.Printf("Error parsing stream:updated payload: %v", err)
			return
		}
		handler(stream)
	})
}

func (oc *ObserveChannel) OnStreamDeleted(handler func(Stream)) {
	oc.channel.On("stream:deleted", func(payload any) {
		var stream Stream
		if err := parsePayload(payload, &stream); err != nil {
			log.Printf("Error parsing stream:deleted payload: %v", err)
			return
		}
		handler(stream)
	})
}

func (oc *ObserveChannel) OnConsumerCreated(handler func(Consumer)) {
	oc.channel.On("consumer:created", func(payload any) {
		var consumer Consumer
		if err := parsePayload(payload, &consumer); err != nil {
			log.Printf("Error parsing consumer:created payload: %v", err)
			return
		}
		handler(consumer)
	})
}

func (oc *ObserveChannel) OnConsumerUpdated(handler func(Consumer)) {
	oc.channel.On("consumer:updated", func(payload any) {
		var consumer Consumer
		if err := parsePayload(payload, &consumer); err != nil {
			log.Printf("Error parsing consumer:updated payload: %v", err)
			return
		}
		handler(consumer)
	})
}

func (oc *ObserveChannel) OnConsumerDeleted(handler func(Consumer)) {
	oc.channel.On("consumer:deleted", func(payload any) {
		var consumer Consumer
		if err := parsePayload(payload, &consumer); err != nil {
			log.Printf("Error parsing consumer:deleted payload: %v", err)
			return
		}
		handler(consumer)
	})
}

func (oc *ObserveChannel) OnMessagesUpserted(handler func([]Message)) {
	oc.channel.On("messages:upserted", func(payload any) {
		type tempPayload struct {
			Messages []Message `json:"messages"`
		}

		var tp tempPayload
		if err := parsePayload(payload, &tp); err != nil {
			log.Printf("Error parsing messages:upserted payload: %v", err)
			return
		}

		handler(tp.Messages)
	})
}