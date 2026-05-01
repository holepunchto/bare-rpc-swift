// Live RPC peer for BareInteropTests.swift.

const io = require('bare-stdio')
const { Duplex } = require('bare-stream')
const RPC = require('bare-rpc')

// Mirrored in BareInteropTests.swift's `Command` enum.
const CMD_REQUEST_STREAM_COLLECTOR = 5
const CMD_RESPONSE_STREAM_PRODUCER = 6
const CMD_REQUEST_STREAM_COLLECTOR_REPLY = 21

// Test-only: ignores backpressure.
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
  if (typeof req.reply !== 'function') return

  switch (req.command) {
    case CMD_REQUEST_STREAM_COLLECTOR: {
      const incoming = req.createRequestStream()
      const chunks = []
      for await (const chunk of incoming) chunks.push(chunk)
      rpc.event(CMD_REQUEST_STREAM_COLLECTOR_REPLY).send(Buffer.concat(chunks))
      break
    }
    case CMD_RESPONSE_STREAM_PRODUCER: {
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

Bare.on('uncaughtException', (err) => {
  io.err.write('peer uncaught: ' + err.message + '\n')
  Bare.exit(1)
})
