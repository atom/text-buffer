const WORDS = require('../spec/helpers/words')
const Random = require('random-seed')
const random = new Random(Date.now())
const {Point, Range} = require('..')

exports.getRandomText = function (sizeInKB) {
  const goalLength = Math.round(sizeInKB * 1024)

  let length = 0
  let lines = []
  let currentLine = ''
  let lastLineStartIndex = 0
  let goalLineLength = random(100)

  for (;;) {
    if (currentLine.length >= goalLineLength) {
      length++
      lines.push(currentLine)
      if (length >= goalLength) break

      currentLine = ''
      goalLineLength = random(100)
    }

    let choice = random(10)
    if (choice < 2) {
      length++
      currentLine += '\t'
    } else if (choice < 4) {
      length++
      currentLine += ' '
    } else {
      if (currentLine.length > 0 && !/\s$/.test(currentLine)) {
        length++
        currentLine += ' '
      }
      word = WORDS[random(WORDS.length)]
      length += word.length
      currentLine += word
    }
  }

  return lines.join('\n') + '\n'
}

exports.getRandomRange = function (buffer) {
  const start = getRandomPoint(buffer)
  const end = getRandomPoint(buffer)
  if (end.isLessThan(start)) {
    return new Range(end, start)
  } else {
    return new Range(start, end)
  }
}

function getRandomPoint (buffer) {
  const row = random(buffer.getLineCount())
  const column = random(buffer.lineLengthForRow(row))
  return new Point(row, column)
}
