const {remote} = require('electron')

const path = require('path')
const Command = require('jasmine/lib/command.js')
const Jasmine = require('jasmine/lib/jasmine.js')

const jasmine = new Jasmine({ projectBaseDir: path.resolve(), color: false })
const examplesDir = path.join(path.dirname(require.resolve('jasmine-core')), 'jasmine-core', 'example', 'node_example')
const command = new Command(path.resolve(), examplesDir, console.log)

process.stdout.write = function (output) {
  console.log(output)
}

process.exit = function () {}
command.run(jasmine, ['--no-color', '--stop-on-failure=true', ...remote.process.argv.slice(2)])
