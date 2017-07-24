const temp = require('temp')
const TextBuffer = require('../src/text-buffer')

describe('TextBuffer', () => {
  let buffer = null

  beforeEach(() => {
    temp.track()
    jasmine.addCustomEqualityTester(require('underscore-plus').isEqual)
    // When running specs in Atom, setTimeout is spied on by default.
    jasmine.useRealClock && jasmine.useRealClock()
  })

  afterEach(() => {
    buffer && buffer.destroy()
    buffer = null
  })

  describe('::scanInRange(range, regex, fn)', () => {
    beforeEach(() => {
      const filePath = require.resolve('./fixtures/sample.js')
      buffer = TextBuffer.loadSync(filePath)
    })

    describe('when given a regex with a unicode flag', () => {
      it('uses unicode regexp', () => {
        const matches = []
        buffer.scanInRange(/\u{63}\u{75}\u{72}\u{72}\u{65}\u{6E}\u{74}/u, [[0, 0], [12, 0]], ({match, range}) => {
          matches.push(match)
        })
        expect(matches.length).toBe(1)
      })
    })
  })
})
