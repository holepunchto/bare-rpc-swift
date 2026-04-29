// Live RPC peer used by BareInteropTests.swift.
//
// Reads bare-rpc frames from stdin and writes them to stdout, running the
// reference JavaScript implementation on the other side of a real pipe.
//
// Invoked as: bare rpc_peer.js
//
// Requires `npm install` to have been run at the repo root so that
// bare-rpc, bare-stream, and bare-stdio are resolvable.

const io = require('bare-stdio')
const { Duplex } = require('bare-stream')
const RPC = require('bare-rpc')

// Mirrored in BareInteropTests.swift (`Command` enum). Keep in sync.
const CMD_REQUEST_STREAM_COLLECTOR = 5
const CMD_RESPONSE_STREAM_PRODUCER = 6
const CMD_REQUEST_STREAM_COLLECTOR_REPLY = 21

// Wrap stdin/stdout as a single Duplex so bare-rpc can treat it as a transport.
// Test-only: we push chunks straight through without honoring backpressure
// because volumes here are tiny — don't copy this pattern into production.
const duplex = new Duplex({
  write(chunk, encoding, cb) {
    io.out.write(chunk, cb)
  },
  read() {}
})

io.in.on('data', (chunk) => duplex.push(chunk))
io.in.on('end', () => {
  duplex.push(null)
  Bare.exit(0)
})

const rpc = new RPC(duplex, async (req) => {
  // Only IncomingRequest has a `reply` method; IncomingEvents are ignored.
  if (typeof req.reply !== 'function') return

  switch (req.command) {
    case CMD_REQUEST_STREAM_COLLECTOR: {
      // Read all chunks from the inbound request stream and emit the
      // concatenation as a reply event. Used to verify Swift → JS request
      // streaming since Swift's createRequestStream is fire-and-forget and
      // has no reply channel.
      const incoming = req.createRequestStream()
      const chunks = []
      for await (const chunk of incoming) chunks.push(chunk)
      rpc.event(CMD_REQUEST_STREAM_COLLECTOR_REPLY).send(Buffer.concat(chunks))
      break
    }
    case CMD_RESPONSE_STREAM_PRODUCER: {
      // Write three fixed chunks to the outbound response stream, then end.
      // Used to verify JS → Swift response streaming.
      const outgoing = req.createResponseStream()
      outgoing.write(Buffer.from([0x0a]))
      outgoing.write(Buffer.from([0x14, 0x1e]))
      outgoing.write(Buffer.from([0x28, 0x32, 0x3c]))
      outgoing.end()
      break
    }
    default: {
      const err = new Error('unknown command ' + req.command)
      err.code = 'EUNKNOWN'
      err.errno = -1
      throw err
    }
  }
})

// Surface any uncaught error to stderr so the Swift harness can see it.
Bare.on('uncaughtException', (err) => {
  io.err.write('peer uncaught: ' + err.message + '\n')
  Bare.exit(1)
})
