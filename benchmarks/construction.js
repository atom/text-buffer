const regression = require('regression')
const helpers = require('./helpers')
const TextBuffer = require('..')

const TRIAL_COUNT = 3
const SIZES_IN_KB = [
  1,
  10,
  100,
  1000,
  10000,
]

const bufferTimesInMS = []
const displayLayerTimesInMS = []

for (let sizeInKB of SIZES_IN_KB) {
  let text = helpers.getRandomText(sizeInKB)
  let buffer = new TextBuffer({text})

  let t0 = Date.now()
  for (let i = 0; i < TRIAL_COUNT; i++) {
    buffer = new TextBuffer({text})
    buffer.getTextInRange([[0, 0], [50, 0]])
  }

  let t1 = Date.now()
  for (let i = 0; i < TRIAL_COUNT; i++) {
    let displayLayer = buffer.addDisplayLayer({})
    displayLayer.getScreenLines(0, 50)
  }

  let t2 = Date.now()
  bufferTimesInMS.push((t1 - t0) / TRIAL_COUNT)
  displayLayerTimesInMS.push((t2 - t1) / TRIAL_COUNT)
}

function getMillisecondsPerMegabyte(timesInMS) {
  const series = timesInMS.map((time, i) => [SIZES_IN_KB[i], time * 1024])
  const slownessRegression = regression('linear', series)
  return slownessRegression.equation[0]
}

console.log('Construction')
console.log('------------')
console.log('TextBuffer:    %s ms/MB', getMillisecondsPerMegabyte(bufferTimesInMS).toFixed(1))
console.log('DisplayLayer:  %s ms/MB', getMillisecondsPerMegabyte(displayLayerTimesInMS).toFixed(1))
