# Bidirectional Forwarding Detection (BFD)

## The Problem with Traditional Routing Convergence

Routing protocols maintain network topology by sending periodic "Hello" or "Keepalive" packets to their neighbors. If a router stops receiving these packets after a defined interval (the "Dead" or "Hold" timer), it assumes the neighbor has failed and recalculates network paths.

| Protocol | Default Hello | Default Dead / Hold | Typical Detection Time |
|----------|---------------|---------------------|------------------------|
| OSPF     | 10 s          | 40 s                | 40 s                   |
| IS-IS    | 10 s          | 30 s                | 30 s                   |
| BGP      | 60 s          | 180 s               | 180 s                  |

While these timers were acceptable in legacy networks, modern environments (voice, video, financial trading, and AI/ML clusters) require sub-second recovery to prevent disruptions.


### Why Not Just Lower the Timers?

It seems logical to simply reduce OSPF or BGP timers to 1 second. However, this creates severe architectural problems:

- **CPU Exhaustion**: Routing protocol Hellos are processed by the router's control-plane CPU. Processing complex Hellos across hundreds of neighbors multiple times a second can overwhelm the processor.

- **False Positives**: If the router's CPU is temporarily busy computing new routes, it might miss a Hello packet. The router would then incorrectly declare a healthy link as "dead," triggering a cascade of unnecessary route recalculations across the network.


## The Solution - Enter BFD

Because routing protocols are too resource-intensive to run at sub-second intervals, the industry developed a lightweight protocol dedicated entirely to path liveness detection.

**Bidirectional Forwarding Detection** (BFD) is a Layer 3 protocol designed to detect faults in the bidirectional forwarding path between two nodes as quickly and cheaply as possible.

### Core Characteristics

- **Protocol-Independent**: BFD does not route traffic. Routing protocols such as OSPF, BGP, and IS-IS register with BFD to monitor paths on their behalf.

- **Extremely Lightweight**: BFD packets use a 24-byte fixed header with no link-state database computations, route selection logic, or path recalculations — unlike routing protocol Hellos, which are tightly coupled to complex protocol machinery that must synchronize topology databases and recompute shortest paths. This makes BFD computationally inexpensive to process.

- **Data-Plane Focused**: Network devices operate on two functional layers: the *control plane* (software that runs routing protocols, builds routing tables, and makes forwarding decisions) and the *data plane* (hardware — ASICs, line cards — that actually forwards packets at wire speed based on those decisions). BFD tests the data plane directly, detecting scenarios where an interface appears "up" in control-plane software but the forwarding hardware is silently dropping packets.

### Integrating BFD with Routing Protocols

When deployed, BFD integrates with routing protocols through a straightforward workflow:

1. **Registration**: A routing protocol (OSPF, BGP, etc.) registers a specific neighbor address with the local BFD process, requesting that BFD monitor the forwarding path to that neighbor.

2. **Monitoring**: BFD exchanges lightweight control packets with the peer at sub-second intervals, completely independent of the routing protocol's own timers.

3. **Detection**: If the forwarding path fails (e.g., a fiber cut or silent hardware failure), BFD misses the expected control packets and declares the session Down within the negotiated detection time.

4. **Notification**: BFD signals the routing protocol immediately. The protocol tears down the adjacency without waiting for its own slow dead timer (40–180 seconds) and recalculates an alternate path.

### Origin and Standardization

BFD was designed by Dave Katz and Dave Ward (both at Juniper Networks at the time). They presented the initial concept at the IETF around 2004. The protocol matured through several years of drafts before being published as a set of core RFCs in 2010:

| RFC  | Title                                    | Year | Key Takeaway                                    |
|------|------------------------------------------|------|-------------------------------------------------|
| 5880 | BFD (base protocol)                      | 2010 | State machine, packet format, timer negotiation |
| 5881 | BFD for IPv4/IPv6 (Single Hop)           | 2010 | UDP/3784, TTL=255 security (GTSM)               |
| 5882 | Generic Application of BFD               | 2010 | Guidelines for protocol integration             |
| 7419 | Common Interval Support in BFD           | 2014 | Standardized timer values across vendors        |

BFD is implemented by all major network vendors (Cisco, Juniper, Arista, Nokia, Huawei) and supported in open-source routing suites such as FRRouting (FRR) and OpenBGPd.


## The BFD Packet on the Wire

### Encapsulation Stack

BFD is a Layer 3 protocol whose payload rides inside standard IP packets:

    Ethernet Frame → IP Header → UDP Header → BFD Control Packet

BFD uses UDP rather than TCP for three deliberate reasons:

- **No Handshakes**: TCP requires a 3-way handshake and connection teardowns. BFD must begin monitoring with zero setup delay.

- **No Retransmissions**: If a TCP packet is lost, the sender pauses and retransmits, causing unpredictable delays. If a UDP BFD packet is lost, the system simply waits for the next one arriving milliseconds later.

- **ECMP Path Coverage**: The sender uses a random ephemeral source port (typically 49152–65535). Intermediate switches use a hash of the packet's 5-tuple (including source and destination ports) to distribute traffic across Equal-Cost Multi-Path (ECMP) links. By varying the source port, BFD probes are hashed across the same set of forwarding paths that production traffic uses, enabling detection of failures on individual ECMP links rather than testing only a single path.

### Destination UDP Ports

The destination UDP port identifies the BFD session type to the receiving router:

| Port | Session Type  | Use Case                                                                          | Reference |
|-----:|---------------|-----------------------------------------------------------------------------------|-----------|
| 3784 | Single-hop    | Directly connected routers on a single link (most common deployment)              | RFC 5881  |
| 3785 | Echo          | Remote hardware loops the packet back without control-plane processing            | RFC 5880  |
| 4784 | [Multihop](#multihop-bfd-rfc-5883)      | Peers separated by one or more intermediate routers                               | RFC 5883  |
| 6784 | [Micro-BFD](#micro-bfd-for-lags-rfc-7130)   | Individual physical links within a Link Aggregation Group (LAG)                   | RFC 7130  |

### The BFD Control Packet

The base BFD control packet is exactly 24 bytes. This fixed, compact size allows hardware ASICs to process millions of packets per second with minimal resource consumption.

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|Vers |  Diag   |Sta|P|F|C|A|D|M|  Detect Mult  |    Length     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       My Discriminator                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      Your Discriminator                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Desired Min TX Interval                    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                   Required Min RX Interval                    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 Required Min Echo RX Interval                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| Field                         | Size     | Description                                                                      |
|-------------------------------|----------|----------------------------------------------------------------------------------|
| Vers (Version)                | 3 bits   | Protocol version (currently 1)                                                   |
| Diag (Diagnostic)             | 5 bits   | Reason for the last session state change (0 = No Diagnostic, 1 = Control Detection Time Expired, 2 = Echo Function Failed, 3 = Neighbor Signaled Session Down, 7 = Administratively Down) |
| Sta (State)                   | 2 bits   | Current session state (AdminDown/Down/Init/Up)                                   |
| P (Poll)                      | 1 bit    | Requests a Final response (used during parameter changes)                        |
| F (Final)                     | 1 bit    | Acknowledgment of a Poll request                                                 |
| C (Control Plane Independent) | 1 bit    | Indicates the sender's BFD implementation can continue running independently of the control plane (e.g., via hardware offload). When set, the peer should maintain the BFD session even if other control-plane protocols (OSPF, BGP) on the sender fail, because BFD itself may still be fully operational in hardware. |
| A (Authentication Present)    | 1 bit    | Authentication section is appended to the packet                                 |
| D (Demand)                    | 1 bit    | Demand mode is active (periodic packets are suppressed)                          |
| M (Multipoint)                | 1 bit    | Reserved for multipoint BFD (not yet standardized)                               |
| Detect Mult                   | 8 bits   | Multiplier applied to the negotiated Rx interval to calculate the detection time (typically 3) |
| Length                        | 8 bits   | Total packet length in bytes                                                     |
| My Discriminator              | 32 bits  | Locally-assigned unique identifier for this session (enables O(1) hash lookup)   |
| Your Discriminator            | 32 bits  | Remote system's discriminator, echoed back to identify the session               |
| Desired Min TX Interval       | 32 bits  | Minimum interval (μs) at which the sender wants to transmit                      |
| Required Min RX Interval      | 32 bits  | Minimum interval (μs) at which the sender can receive                            |
| Required Min Echo RX Interval | 32 bits  | Minimum interval (μs) at which the sender can process Echo packets               |


## Session Scope - Per-Path, Not Per-Neighbor

A BFD session monitors a single forwarding path, not an entire neighbor relationship. If two routers are connected by multiple routed links, each link runs its own independent BFD session with its own timers and state machine. A failure on one link tears down only that link's session; the remaining links and their sessions are unaffected.

Each side assigns a locally unique **My Discriminator** (a 32-bit value in the control packet) to every session it creates. The peer echoes this value back as **Your Discriminator**. This discriminator pair is what allows a router to maintain multiple simultaneous BFD sessions with the same neighbor — one per monitored path — and demultiplex incoming packets to the correct session in O(1) time.

When multiple links are bundled into a Link Aggregation Group (LAG), standard BFD sees only the single logical interface and cannot detect individual member link failures. [Micro-BFD](#micro-bfd-for-lags-rfc-7130), covered in the Advanced Implementations section, addresses this by running a separate BFD session on each physical member link.


## BFD Operating Modes

RFC 5880 defines two primary operating modes and one supplementary mechanism for BFD. These dictate how established sessions exchange and process BFD control packets. Asynchronous Mode is mandatory — every compliant BFD implementation must support it. Demand Mode and the Echo Function are optional — implementations may support them but are not required to.

### Asynchronous Mode

Both systems periodically send BFD control packets to each other. If a system does not receive a packet within the negotiated detection time, the session is declared Down. This is the default and most widely deployed mode. It is conceptually similar to the keepalive/hello mechanisms used by routing protocols, but far lighter in processing cost.

### Demand Mode

Once a session is established, periodic packet transmission stops. Instead, either system can explicitly verify path liveness on-demand by sending a BFD control packet with the Poll (P) bit set, expecting a response with the Final (F) bit set. Demand mode is highly efficient when an alternative mechanism (like physical-layer signal loss detection) already provides failure detection. It reduces BFD overhead traffic to near zero during normal operations.

### Echo Function

A system sends BFD Echo packets (via UDP port 3785) that the remote end simply loops back through its forwarding path without processing them in the control plane. The originating system uses the returned (or missing) Echo packets to determine the health of the forwarding path.

- **Forwarding-path validation**: Echo packets traverse the remote system's actual forwarding hardware — the ASICs, line cards, and switching fabric that forward production traffic — rather than just confirming that the remote control-plane CPU is reachable.
- **Reduced remote load**: Echo packets are forwarded in hardware on the remote end, requiring no BFD software processing.
- **Asymmetric detection**: The local system can achieve very fast detection times independent of the remote system's BFD processing capability.


## How BFD Works Under the Hood

With the high-level purpose and modes established, we can look at how BFD sessions are formed, maintained, and managed.

### Session Establishment

BFD sessions can be established using two initiation roles (distinct from the Asynchronous/Demand operating modes above, which govern how an established session behaves):

**Active role**: The system actively begins sending BFD control packets regardless of whether it has received anything from the peer. At least one side must be in the active role for a session to come up.

**Passive role**: The system does not initiate BFD packets. It waits until it receives a BFD control packet from the peer and only then begins responding. The passive role reduces unnecessary BFD traffic when the remote end might not yet be configured.

Once the session is established, both sides operate symmetrically regardless of which role initiated it.

### The State Machine

BFD sessions progress through the following states:

- **AdminDown**: Administratively disabled; the session is not operational.
- **Down**: The initial state, or the state entered when the session fails.
- **Init**: The local system has detected a peer (received a Down state) and is signaling readiness.
- **Up**: Both systems are exchanging packets at the negotiated interval; the path is healthy.

```
System A                                  System B
   |                                         |
   |--- BFD Control (State=Down) ----------->|
   |<-- BFD Control (State=Init) ------------|
   |--- BFD Control (State=Up) ------------->|
   |<-- BFD Control (State=Up) --------------|
   |                                         |
   |=== Session is UP, periodic exchange ====|
   |                                         |
   |--- BFD Control (every Tx interval) ---->|
   |<-- BFD Control (every Tx interval) -----|
   |                                         |
   |    (System B fails)                     |
   |                                         |
   |--- BFD Control --->  X  (no response)   |
   |--- BFD Control --->  X  (no response)   |
   |--- BFD Control --->  X  (no response)   |
   |                                         |
   | Detect time expired -> Session DOWN     |
   | -> Notify OSPF/BGP/etc.                 |
```

| Current State | Event                             | New State |
|---------------|-----------------------------------|-----------|
| Down          | Receive BFD with State=Down       | Init      |
| Down          | Receive BFD with State=Init       | Up        |
| Init          | Receive BFD with State=Init or Up | Up        |
| Up            | Detect timer expires              | Down      |
| Up            | Receive BFD with State=Down       | Down      |
| Any           | Administrative action             | AdminDown |

### Timer Negotiation and Failure Detection

BFD timers are dynamically negotiated during session initialization to ensure neither side transmits faster than the other can process. Each side advertises its capabilities via three fields in the control packet:

- Desired Min TX Interval
- Required Min RX Interval
- Detect Multiplier

The actual transmit interval is calculated as the maximum of what one side wants to send and what the other side can handle:

$$\text{Actual Tx Interval} = \max(\text{Local Desired Min Tx}, \text{Remote Required Min Rx})$$

The failure detection threshold is then determined by multiplying that negotiated interval by the multiplier:

$$\text{Detection Time} = \text{Detect Multiplier} \times \text{Negotiated Rx Interval}$$

The following table shows how different interval and multiplier combinations affect detection time in common deployment scenarios:

| Environment        | Tx/Rx Interval | Detect Mult. | Detection Time |
| ------------------ | -------------: | -----------: | -------------: |
| Aggressive (DC)    |          50 ms |            3 |         150 ms |
| Standard           |         100 ms |            3 |         300 ms |
| Conservative       |         300 ms |            3 |         900 ms |
| Very Conservative  |        1000 ms |            3 |            3 s |

### Jitter (Preventing Synchronization)

If a router has thousands of active BFD sessions, transmitting all control packets at the exact same instant would cause CPU spikes and traffic micro-bursts.

To prevent this, BFD implementations apply random jitter to the transmit interval. Each transmission is randomly delayed by up to 25% of the interval. When the detect multiplier is 1, the jitter range increases to 90% — because a single missed packet would immediately declare the session Down, the wider jitter window maximizes desynchronization between sessions and reduces the probability that a transient CPU spike causes multiple sessions to miss their sole detection window simultaneously.

### Graceful Timer Changes (The Poll Sequence)

A router under heavy load may need to request slower BFD intervals from its peer. To change timer values without triggering a false session failure, BFD uses a Poll Sequence:

1. The burdened router sends a packet with the **P (Poll)** bit set, containing its new timer values.
2. The peer acknowledges by responding with the **F (Final)** bit set.
3. Both sides adopt the new timer values only after this exchange completes, ensuring a graceful transition.


## Security Considerations

### TTL Security (GTSM)

Because UDP is connectionless, BFD is susceptible to spoofing. An attacker several hops away could craft fake BFD packets to disrupt routing.

For single-hop sessions, BFD mitigates this with the Generalized TTL Security Mechanism (GTSM), defined in RFC 5082:

1. The sender sets the IP Time-To-Live (TTL) field to 255 (the maximum value).
2. Each router along a path decrements the TTL by 1.
3. The receiver discards any BFD packet with a TTL below 255.

Since any packet originating from a non-directly-connected source must traverse at least one intermediate hop (reducing TTL to 254 or less), this guarantees that accepted packets originated from the directly connected peer.

### Authentication

BFD supports cryptographic authentication to prevent session spoofing and replay attacks. RFC 5880 defines these types:

| Type                       | Auth Code | Security Level                                         |
|----------------------------|-----------|--------------------------------------------------------|
| Simple Password            | 1         | Cleartext; not recommended for production              |
| Keyed MD5                  | 2         | MD5 hash with shared key                               |
| Meticulous Keyed MD5       | 3         | MD5 with per-packet sequence number (replay-resistant) |
| Keyed SHA-1                | 4         | SHA-1 hash with shared key                             |
| Meticulous Keyed SHA-1     | 5         | SHA-1 with per-packet sequence number (replay-resistant) |

"Meticulous" variants require monotonically incrementing sequence numbers on every packet, providing replay protection at the cost of slightly more processing overhead.

### Rate Limiting

BFD implementations should rate-limit session creation and state transitions to prevent resource exhaustion from malicious or misconfigured peers.


## Hardware Offload

Even though BFD is lightweight, maintaining hundreds of sub-100ms timers on a general-purpose control-plane CPU can introduce timing inaccuracies under load. Hardware offload addresses this by delegating BFD packet generation and reception to dedicated network silicon (ASICs or NPUs) on the line card.

Benefits:

- **CPU Independence**: Hardware timers are serviced with deterministic precision, completely unaffected by control-plane CPU load (e.g., during large-scale BGP table reconvergence).

- **Lower Intervals**: Hardware offload enables BFD transmit and receive intervals as low as 3–10 milliseconds, unreachable with software-only implementations.


## Advanced Implementations

### Multihop BFD (RFC 5883)

**Problem**: Standard single-hop BFD uses GTSM (TTL=255) to verify that packets originate from a directly connected peer. However, some sessions — such as multi-hop eBGP peerings between loopback interfaces separated by intermediate routers — cannot use TTL=255 because intermediate hops decrement the TTL below the acceptance threshold.

**Solution**: Multihop BFD uses UDP destination port 4784 and disables the TTL=255 check, allowing packets to be routed across multiple hops. Because GTSM protection is unavailable in this mode, Multihop BFD relies on cryptographic authentication (Keyed SHA-1 or stronger) within the BFD packet to prevent injection of spoofed session-teardown messages.

### BFD for MPLS LSPs (RFC 5884)

**Background**: Multiprotocol Label Switching (MPLS) forwards packets based on short labels rather than IP addresses, creating predetermined tunnels called Label Switched Paths (LSPs). These tunnels are unidirectional — Router A's path to Router Z may differ from Router Z's return path to Router A.

**Problem**: If an intermediate router's label table becomes corrupted, the MPLS tunnel breaks at the data plane. A standard IP-routed BFD packet between the endpoints might bypass the broken tunnel entirely via normal IP forwarding, falsely indicating path health while customer traffic is being dropped.

**Solution**: BFD packets are encapsulated beneath the same MPLS label stack as production traffic, forcing them to traverse the identical physical path. When the egress router receives the BFD probe at the tunnel endpoint, it strips the MPLS labels, processes the BFD control packet, and returns its response via standard IP routing. This validates that the unidirectional MPLS tunnel is actively forwarding data end-to-end.

### Micro-BFD for LAGs (RFC 7130)

**Background**: Link Aggregation Groups (LAGs) bundle multiple physical links between two switches into a single logical interface. The *Link Aggregation Control Protocol* (LACP) manages the bundle and distributes traffic across member links via hashing.

**Problem**: LACP detects member link failures slowly (1–3 seconds in fast mode, up to 90 seconds in slow mode) and only monitors at the control plane. If a single physical link experiences a silent data-plane failure (e.g., optics degrade but the electrical signal persists), LACP continues hashing traffic onto the failed link, creating a persistent black hole for a fraction of all flows.

**Solution**: Micro-BFD runs an independent BFD session on each physical member link (UDP port 6784). If any individual link's data plane fails, the corresponding Micro-BFD session detects the failure in milliseconds and signals LACP to remove that link from the hashing algorithm. Remaining links absorb the traffic without dropping the entire logical interface.

### Seamless BFD (RFC 7880)

**Background**: Standard BFD requires a three-way handshake to establish a session. Both endpoints allocate memory and maintain state for the session's lifetime.

**Problem**: In large-scale environments — such as Segment Routing fabrics or centralized SDN controllers — a single node may need to verify the health of tens of thousands of paths simultaneously. Maintaining a full BFD state machine for each path creates prohibitive memory and CPU overhead on the target nodes.

**Solution**: Seamless BFD (S-BFD) eliminates the handshake and per-session state on the target. The target router operates as a stateless "Reflector": it listens on a well-known S-BFD port and, upon receiving a probe, swaps the source and destination addresses and returns the packet immediately. The initiating controller receives the reflected packet and confirms path liveness. Because the Reflector maintains no per-session state, this model scales to arbitrarily large numbers of monitored paths without burdening target nodes.
