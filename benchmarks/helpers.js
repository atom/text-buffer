const WORDS = require('../spec/helpers/words')
const Random = require('random-seed')
const random = new Random(Date.now())

exports.getRandomText = function (sizeInKB) {
  const goalLength = sizeInKB * 1024

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
