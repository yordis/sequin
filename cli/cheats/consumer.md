# To list consumers for a stream

sequin consumer ls [stream-id]

# To add a new consumer to a stream

sequin consumer add [stream-id] [slug]

# To show consumer information

sequin consumer info [stream-id] [consumer-id]

# To pull next messages for a consumer (default batch size is 1)

sequin consumer next [stream-id] [consumer-id]

# To pull next messages for a consumer without acknowledging them

sequin consumer next [stream-id] [consumer-id] --no-ack

# To pull next messages for a consumer and ack them

sequin consumer next [stream-id] [consumer-id]

# To pull a batch of messages for a consumer

sequin consumer next [stream-id] [consumer-id] --batch-size 10

# To peek at messages for a consumer (default shows last 10 messages)

sequin consumer peek [stream-id] [consumer-id]

# To peek only at pending messages for a consumer

sequin consumer peek [stream-id] [consumer-id] --pending

# To peek at the last N messages for a consumer

sequin consumer peek [stream-id] [consumer-id] --last 20

# To peek at the first N messages for a consumer

sequin consumer peek [stream-id] [consumer-id] --first 20

# To acknowledge a message

sequin consumer ack [stream-id] [consumer-id] [ack-id]