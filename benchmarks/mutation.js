const helpers = require('./helpers')
const TextBuffer = require('..')

let text = helpers.getRandomText(100)
let buffer = new TextBuffer({text})
let displayLayer = buffer.addDisplayLayer({})

let t0 = Date.now()

for (let i = 0; i < 1000; i++) {
  buffer.setTextInRange(
    helpers.getRandomRange(buffer),
    helpers.getRandomText(0.5)
  )
}

let t1 = Date.now()

console.log('Mutation')
console.log('------------')
console.log('TextBuffer:    %s ms', t1 - t0)
