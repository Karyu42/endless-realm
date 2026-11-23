class_name ProtocolCodec
extends RefCounted
## Interim JSON codec for protocol v1 WebSocket frames.
## Follow-up: replace with godobuf against proto/v1/protocol.proto.
## The dictionary shapes match Hello, Welcome, Reject, InputFrame, and Snapshot.


func encode(msg: Dictionary) -> PackedByteArray:
	return JSON.stringify(msg).to_utf8_buffer()


func decode(buf: PackedByteArray) -> Dictionary:
	if buf.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(buf.get_string_from_utf8())
	if parsed is Dictionary:
		return parsed
	return {}
