const helpers = require('./helpers')
const TextBuffer = require('..')

const text = helpers.getRandomText(100)
const buffer = new TextBuffer({ text })
// const displayLayer = buffer.addDisplayLayer({})

const t0 = Date.now()

for (let i = 0; i < 1000; i++) {
  buffer.setTextInRange(
    helpers.getRandomRange(buffer),
    helpers.getRandomText(0.5)
  )
}

const t1 = Date.now()

console.log('Mutation')
console.log('------------')
console.log('TextBuffer:    %s ms', t1 - t0)
