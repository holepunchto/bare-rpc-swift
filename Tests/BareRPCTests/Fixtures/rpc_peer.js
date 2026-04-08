// Live RPC peer used by NodeInteropTests.swift.
//
// Reads bare-rpc frames from stdin and writes them to stdout, running the
// reference JavaScript implementation on the other side of a real pipe.
//
// Invoked as: node rpc_peer.js <path-to-bare-rpc-checkout>
//
// The path argument lets us point at a sibling checkout of holepunchto/bare-rpc
// (with its node_modules installed) without requiring an npm install inside
// this repo.

const path = require('path')
const { Duplex } = require('stream')

const bareRpcPath = process.argv[2]
if (!bareRpcPath) {
  console.error('usage: node rpc_peer.js <path-to-bare-rpc>')
  process.exit(2)
}

const RPC = require(path.resolve(bareRpcPath))

// Wrap stdin/stdout as a single Duplex so bare-rpc can treat it as a transport.
const duplex = new Duplex({
  write(chunk, encoding, cb) {
    process.stdout.write(chunk, cb)
  },
  read() {}
})

process.stdin.on('data', (chunk) => duplex.push(chunk))
process.stdin.on('end', () => {
  duplex.push(null)
  process.exit(0)
})

const rpc = new RPC(duplex, async (req) => {
  // Only IncomingRequest has a `reply` method; IncomingEvents are ignored.
  if (typeof req.reply !== 'function') return

  switch (req.command) {
    case 5: {
      // request-stream collector: read all chunks from the inbound request
      // stream and emit the concatenation as event 21. Used to verify Swift
      // → JS request streaming since Swift's createRequestStream is
      // fire-and-forget and has no reply channel.
      const incoming = req.createRequestStream()
      const chunks = []
      for await (const chunk of incoming) chunks.push(chunk)
      rpc.event(21).send(Buffer.concat(chunks))
      break
    }
    case 6: {
      // response-stream producer: write three fixed chunks to the outbound
      // response stream, then end. Used to verify JS → Swift response
      // streaming.
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

// Silence unhandled rejections that might come from the bare-rpc internals
// during shutdown so they don't pollute stderr and confuse the Swift harness.
process.on('uncaughtException', (err) => {
  process.stderr.write('peer uncaught: ' + err.message + '\n')
  process.exit(1)
})
