# Claude Messages API Examples

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/messages-examples

Based on the Claude Docs page, here are the key API use cases:

## Basic Request/Response

The simplest pattern sends a user message and receives an assistant response.
The Messages API is stateless, which means that you always send the full
conversational history to the API.

## Multi-Turn Conversations

Build conversations by maintaining message history. Each request includes prior
exchanges, allowing Claude to maintain context across interactions.

## Response Prefilling

Pre-fill Claude's response to shape outputs. This technique works by putting
words in Claude's mouth in the final message position, useful for constraining
responses to specific formats.

## Vision Capabilities

Claude processes images via two methods:

- Base64-encoded image data
- URL-referenced images

Supported formats include JPEG, PNG, GIF, and WebP. The documentation shows
querying image content with text prompts.

## Advanced Features

The page references additional capabilities:

- Tool use and function calling
- JSON mode for structured outputs
- Computer use tools for desktop automation

## Key Parameters

Essential request fields include:

- `model`: Specifies Claude version
- `max_tokens`: Controls response length
- `messages`: Array of conversation turns

The documentation emphasizes that earlier conversational turns don't necessarily
need to actually originate from Claude — you can use synthetic `assistant`
messages.

## Related Documentation

- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
- [Streaming vs Single Mode](./streaming-vs-single-mode.md)
