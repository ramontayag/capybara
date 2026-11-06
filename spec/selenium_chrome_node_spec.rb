# frozen_string_literal: true

require 'spec_helper'
require 'selenium-webdriver'
require 'capybara/selenium/nodes/chrome_node'

RSpec.describe Capybara::Selenium::ChromeNode do
  let(:session) { Capybara::Session.new(:selenium_chrome_headless) }
  let(:driver) { session.driver }
  let(:native) { instance_double(Selenium::WebDriver::Element, displayed?: true, text: 'Finished') }
  let(:node) { described_class.new(driver, native) }
  let(:message) { 'unknown error: unhandled inspector error: {"code":-32000,"message":"Node with given id does not belong to the document"}' }
  let(:error) { Selenium::WebDriver::Error::UnknownError.new(message) }

  before do
    allow(node).to receive(:native_displayed?).and_return(false)
    allow(driver).to receive(:find_xpath).and_return([node])
    allow(driver).to receive(:find_css).and_return([node])
  end

  shared_examples 'a retryable document read' do |method, receiver_method, operation|
    it "converts #{method} document errors to retryable query errors" do
      receiver = receiver_method == :evaluate_script ? driver : native
      allow(receiver).to receive(receiver_method).and_raise(error)

      expect { node.public_send(method) }.to raise_error(Capybara::RetryableQueryError) { |raised|
        expect(raised.message).to include(message)
        expect(raised.cause).to equal(error)
      }
    end

    it "retries #{method} through the document assertion" do
      receiver = receiver_method == :evaluate_script ? driver : native
      calls = 0
      allow(receiver).to receive(receiver_method) do
        calls += 1
        raise error if calls == 1

        receiver_method == :displayed? ? true : 'Finished'
      end

      expect(operation.call(session)).to be true
      expect(calls).to be >= 2
    end

    it "preserves unrelated UnknownError from #{method}" do
      receiver = receiver_method == :evaluate_script ? driver : native
      other = Selenium::WebDriver::Error::UnknownError.new('browser disconnected')
      allow(receiver).to receive(receiver_method).and_raise(other)

      expect { node.public_send(method) }.to raise_error { |raised| expect(raised).to equal(other) }
    end

    it "preserves other exception classes from #{method} even with the same message" do
      receiver = receiver_method == :evaluate_script ? driver : native
      other = Selenium::WebDriver::Error::JavascriptError.new(message)
      allow(receiver).to receive(receiver_method).and_raise(other)

      expect { node.public_send(method) }.to raise_error { |raised| expect(raised).to equal(other) }
    end
  end

  include_examples 'a retryable document read', :visible_text, :text, ->(page) { page.has_text?('Finished') }
  include_examples 'a retryable document read', :all_text, :evaluate_script, ->(page) { page.has_text?(:all, 'Finished') }
  include_examples 'a retryable document read', :visible?, :displayed?, ->(page) { page.has_css?('html') }

  it 'converts document errors from the native visibility endpoint' do
    bridge = double('bridge')
    allow(node).to receive(:native_displayed?).and_return(true)
    allow(node).to receive(:bridge).and_return(bridge)
    allow(native).to receive(:ref).and_return([:element, 'element-id'])
    allow(bridge).to receive(:execute).with(:is_element_displayed, id: 'element-id').and_raise(error)

    expect { node.visible? }.to raise_error(Capybara::RetryableQueryError)
  end

  it 'does not treat a failed text read as proof that text is absent' do
    calls = 0
    allow(native).to receive(:text) do
      calls += 1
      raise error if calls == 1

      'Still here'
    end

    expect(session.has_no_text?('Still here', wait: 0.02)).to be false
    expect(calls).to be >= 2
  end

  it 'raises when document reads keep failing at the existing deadline' do
    allow(native).to receive(:text).and_raise(error)

    expect { session.has_no_text?('Absent', wait: 0) }.to raise_error(Capybara::RetryableQueryError)
    expect(native).to have_received(:text).once
  end

  it 'does not convert errors from clicks or repeat the click' do
    allow(native).to receive(:click).and_raise(error)

    expect { session.find(:css, 'button').click }.to raise_error { |raised| expect(raised).to equal(error) }
    expect(native).to have_received(:click).once
  end

  it 'does not change text errors for other Selenium nodes' do
    allow(native).to receive(:text).and_raise(error)

    expect { Capybara::Selenium::Node.new(driver, native).visible_text }.to raise_error { |raised| expect(raised).to equal(error) }
  end

  it 'keeps unrelated read errors out of the document retry loop' do
    other = Selenium::WebDriver::Error::UnknownError.new('browser disconnected')
    allow(native).to receive(:text).and_raise(other)

    expect { session.has_text?('Finished') }.to raise_error { |raised| expect(raised).to equal(other) }
    expect(native).to have_received(:text).once
  end

  it 'can confirm absent text after a successful replacement document read' do
    calls = 0
    allow(native).to receive(:text) do
      calls += 1
      raise error if calls == 1

      'Replacement document'
    end

    expect(session.has_no_text?('Old document')).to be true
    expect(calls).to eq(2)
  end

  it 'does not repeat a completed click when the following assertion retries' do
    allow(native).to receive(:click)
    calls = 0
    allow(native).to receive(:text) do
      calls += 1
      raise error if calls == 1

      'Finished'
    end

    session.find(:css, 'button').click
    expect(session.has_text?('Finished')).to be true
    expect(native).to have_received(:click).once
  end

  it 'does not treat a failed visibility read as proof that a selector is absent' do
    calls = 0
    allow(native).to receive(:displayed?) do
      calls += 1
      raise error if calls == 1

      true
    end

    expect(session.has_no_css?('html', wait: 0.02)).to be false
    expect(calls).to be >= 2
  end

  it 'requeries before confirming a selector is absent after a failed visibility read' do
    allow(native).to receive(:displayed?).and_raise(error)
    allow(driver).to receive(:find_css).and_return([node], [])

    expect(session.has_no_css?('html')).to be true
    expect(driver).to have_received(:find_css).twice
  end

  [0, 0.02].each do |wait|
    it "raises instead of confirming absence when visibility fails for the entire #{wait} second wait" do
      allow(native).to receive(:displayed?).and_raise(error)

      expect { session.has_no_css?('html', wait: wait) }.to raise_error(Capybara::RetryableQueryError)
    end
  end

  it 'does not treat a failed selector text filter as proof of absence' do
    calls = 0
    allow(native).to receive(:text) do
      calls += 1
      raise error if calls == 1

      'Finished'
    end

    expect(session.has_no_css?('html', text: 'Finished', wait: 0.02)).to be false
    expect(calls).to be >= 2
  end

  it 'preserves an explicit synchronization error list' do
    allow(native).to receive(:text).and_raise(error)

    expect do
      session.document.synchronize(0.02, errors: []) { node.visible_text }
    end.to raise_error(Capybara::RetryableQueryError)
    expect(native).to have_received(:text).once
  end

  it 'propagates failed reads from a custom selector filter until a valid read is available' do
    calls = 0
    allow(native).to receive(:text) do
      calls += 1
      raise error if calls == 1

      'Finished'
    end

    expect(session.has_no_css?('html', wait: 0.02) { |element| element.text == 'Finished' }).to be false
    expect(calls).to be >= 2
  end
end
