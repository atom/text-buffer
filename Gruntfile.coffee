module.exports = (grunt) ->
  grunt.initConfig
    pkg: grunt.file.readJSON('package.json')

    shell:
      test:
        command: 'node node_modules/.bin/jasmine-focused --coffee --captureExceptions --forceexit spec'
        options:
          stdout: true
          stderr: true
          failOnError: true

      'update-atomdoc':
        command: 'npm update grunt-atomdoc donna tello atomdoc'
        options:
          stdout: true
          stderr: true
          failOnError: true

  grunt.loadNpmTasks('grunt-contrib-coffee')
  grunt.loadNpmTasks('grunt-shell')
  grunt.loadNpmTasks('grunt-atomdoc')
