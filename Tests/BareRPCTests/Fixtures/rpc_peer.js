// Live RPC peer used by BareInteropTests.swift.
//
// Reads bare-rpc frames from stdin and writes them to stdout, running the
// reference JavaScript implementation on the other side of a real pipe.
//
// Invoked as: bare rpc_peer.js
//
// Requires `npm install` to have been run in this directory so that
// bare-rpc and bare-process are resolvable.

const process = require('bare-process')
const { Duplex } = require('bare-stream')
const RPC = require('bare-rpc')

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

// Surface any uncaught error to stderr so the Swift harness can see it.
Bare.on('uncaughtException', (err) => {
  process.stderr.write('peer uncaught: ' + err.message + '\n')
  process.exit(1)
})
