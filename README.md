# BeeBEEP Flutter Client

Simple LAN chat, file sharing, and voice messages for BeeBEEP‑style peers.

## Workflow (simple words)
1. **Start** the app and enable discovery.
2. **Discover** peers on the same LAN.
3. **Connect** to a peer and exchange HELLO messages.
4. **Secure** the connection with ECDH keys.
5. **Chat** with text, **send files**, or **record voice**.
6. **Save** message history locally (Hive).
7. **Notify** on new messages when the app is in background.

## Diagram
```mermaid
flowchart LR
	A[App Start] --> B[Start TCP Server]
	B --> C[Bonjour Discovery]
	C --> D[Peer Found]
	D --> E[Connect + HELLO]
	E --> F[Secure Session (ECDH)]
	F --> G[Chat / File / Voice]
	G --> H[Persist to Hive]
	G --> I[Local Notification]
```

## Features
- LAN peer discovery (Bonjour/mDNS).
- Encrypted TCP chat.
- File transfer (chunked) and voice messages.
- Persistent message history (Hive).
- Connection logs and simple settings UI.

## Clean Architecture Status
This codebase is **partially** aligned with Clean Architecture:
- **Presentation / Domain / Data** layers exist under `lib/src/`.
- Use-cases and repositories are separated in the **domain** layer.
- Data sources and repository implementations live in the **data** layer.

Work still needed:
- Enforce strict dependency direction (presentation -> domain -> data only).
- Isolate protocol/transport details from presentation state and UI logic.
- Ensure entities and use-cases stay free of Flutter/framework types.

## Technical Notes
- **Discovery:** mDNS (Bonjour) advertises `_beebeep._tcp` and scans LAN peers.
- **Transport:** TCP sockets with Qt‑style framing (16/32‑bit prefixes).
- **Handshake:** HELLO exchange, then ECDH session key.
- **Encryption:** AES session cipher after ECDH; initial cipher for HELLO.
- **Files/Voice:** Sent as chunked `BEE-FILE` frames with metadata.
- **Persistence:** Chat history stored in Hive, peer display names cached.
- **Default port:** 6475 (fallback to ephemeral if busy).
- **Saved files:** app documents directory under `beebeep_files/`.

## Current Status (Known Issues)
- **File download from BeeBEEP desktop times out** after the transfer is queued.
	- Log example: "Connection timeout" during file download session.
	- Upload attempts are sent, but the peer times out before data transfer completes.
	- File transfer protocol parity is in progress.

## File Structure (high level)
```
lib/
	main.dart
	src/
		core/
			crypto/
			network/
			protocol/
		data/
			datasources/
			repositories/
			models/
		domain/
			entities/
			repositories/
			use_cases/
		presentation/
			app/
			bloc/
			pages/
			services/
packages/
	voice_message_recorder/
```

## License & Attribution
This project is inspired by the BeeBEEP protocol and behavior.
Please review the original BeeBEEP project and license before distribution:
https://github.com/Stkai/BeeBEEP

> If your release requires strict protocol compatibility or licensing
> obligations, validate against BeeBEEP’s license and documentation.
