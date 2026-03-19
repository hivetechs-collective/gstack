# Message Batches Examples

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/messages-batch-examples

Based on the Claude Docs page, here are the key batch processing patterns:

## Core Operations

**Creating Batches**: Submit multiple requests with custom IDs and message
parameters. Each request includes a custom_id, model specification, max_tokens,
and message content.

**Polling for Completion**: Retrieve batch status using its ID and check when
`processing_status` changes to "ended". The example shows checking every 60
seconds until completion.

**Listing Batches**: Use pagination to retrieve all batches in a workspace, with
automatic page fetching as needed.

**Retrieving Results**: Once a batch reaches "ended" status, access results via
`results_url` as a `.jsonl` file. Results stream memory-efficiently, processing
one result at a time.

**Canceling Batches**: Initiate cancellation, which sets status to "canceling"
before finalizing as "ended". Partial results may still be available.

## Key Response Fields

- `id`: Unique batch identifier
- `processing_status`: Current state (in_progress, ended, canceling)
- `request_counts`: Tracks processing, succeeded, errored, canceled, and expired
  requests
- `results_url`: Available after batch completion

## Code Examples

The documentation provides Python, TypeScript, and Shell implementations for all
operations, demonstrating practical integration patterns for production
workflows.

## Related Documentation

- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
- [Cost Tracking](./cost-tracking.md)
