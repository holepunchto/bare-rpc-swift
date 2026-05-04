// Regenerates the hex fixtures used by InteropFixturesTests.swift.
// Run as: bare gen_fixtures.js

const { header } = require('bare-rpc/messages')
const { type: t, stream: s } = require('bare-rpc/constants')

function enc(m, body) {
  const state = { start: 0, end: 0, buffer: null }
  header.preencode(state, m)
  if (body) state.end += body.length
  state.buffer = Buffer.alloc(state.end)
  header.encode(state, m)
  if (body) {
    body.copy(state.buffer, state.start)
    state.start += body.length
  }
  return state.buffer
}

const hex = (buf) => buf.toString('hex')

const fixtures = {
  request_simple: hex(
    enc(
      { type: t.REQUEST, id: 1, command: 42, stream: 0, data: Buffer.from('hello') },
      Buffer.from('hello')
    )
  ),
  request_empty_data: hex(
    enc({ type: t.REQUEST, id: 2, command: 7, stream: 0, data: Buffer.alloc(0) }, Buffer.alloc(0))
  ),
  event_with_data: hex(
    enc(
      {
        type: t.REQUEST,
        id: 0,
        command: 99,
        stream: 0,
        data: Buffer.from([0xde, 0xad, 0xbe, 0xef])
      },
      Buffer.from([0xde, 0xad, 0xbe, 0xef])
    )
  ),
  request_stream_open: hex(enc({ type: t.REQUEST, id: 3, command: 5, stream: s.OPEN, data: null })),
  response_success: hex(
    enc(
      { type: t.RESPONSE, id: 1, stream: 0, error: null, data: Buffer.from('world') },
      Buffer.from('world')
    )
  ),
  response_error: hex(
    enc({
      type: t.RESPONSE,
      id: 1,
      stream: 0,
      error: { message: 'boom', code: 'EBOOM', errno: -2 }
    })
  ),
  response_error_zero_errno: hex(
    enc({
      type: t.RESPONSE,
      id: 5,
      stream: 0,
      error: { message: 'x', code: 'E', errno: 0 }
    })
  ),
  response_stream_open: hex(
    enc({ type: t.RESPONSE, id: 4, stream: s.OPEN, error: null, data: null })
  ),
  stream_data_request: hex(
    enc(
      {
        type: t.STREAM,
        id: 3,
        stream: s.REQUEST | s.DATA,
        error: null,
        data: Buffer.from('abc')
      },
      Buffer.from('abc')
    )
  ),
  stream_end_request: hex(
    enc({
      type: t.STREAM,
      id: 3,
      stream: s.REQUEST | s.END,
      error: null,
      data: null
    })
  ),
  stream_destroy_response: hex(
    enc({
      type: t.STREAM,
      id: 4,
      stream: s.RESPONSE | s.DESTROY,
      error: null,
      data: null
    })
  ),
  stream_error_request: hex(
    enc({
      type: t.STREAM,
      id: 3,
      stream: s.REQUEST | s.ERROR,
      error: { message: 'nope', code: 'ENOPE', errno: -1 },
      data: null
    })
  ),
  request_large_id: hex(
    enc(
      { type: t.REQUEST, id: 1000, command: 1, stream: 0, data: Buffer.alloc(0) },
      Buffer.alloc(0)
    )
  ),
  request_max32_id: hex(
    enc(
      {
        type: t.REQUEST,
        id: 0xfffffffe,
        command: 2,
        stream: 0,
        data: Buffer.from([1, 2, 3])
      },
      Buffer.from([1, 2, 3])
    )
  )
}

console.log(JSON.stringify(fixtures, null, 2))
