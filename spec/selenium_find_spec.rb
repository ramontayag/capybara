# frozen_string_literal: true

require 'spec_helper'
require 'selenium-webdriver'

RSpec.describe Capybara::Selenium::Find do
  let(:session) { Capybara::Session.new(:selenium_chrome_headless) }
  let(:driver) { session.driver }
  let(:elements) { Array.new(3) { instance_double(Selenium::WebDriver::Element, displayed?: true, text: 'Still here') } }
  let(:browser) do
    instance_double(Selenium::WebDriver::Driver,
                    browser: :chrome,
                    find_elements: elements,
                    bridge: instance_double(Selenium::WebDriver::Remote::Bridge, read_atom: 'function() { return true; }'))
  end
  let(:error) do
    Selenium::WebDriver::Error::UnknownError.new(
      'unknown error: unhandled inspector error: {"code":-32000,"message":"Node with given id does not belong to the document"}'
    )
  end

  before do
    allow(driver).to receive(:browser).and_return(browser)
    allow(browser).to receive(:execute_script) { Array.new(3) { [true] } }
  end

  def fail_first_hint_read
    calls = 0
    allow(browser).to receive(:execute_script) do
      calls += 1
      raise error if calls == 1

      Array.new(3) { [true] }
    end
  end

  it 'requeries the document after a visibility-hint inspector error' do
    fail_first_hint_read

    expect(session.has_css?('a', count: 3)).to be true
    expect(browser).to have_received(:find_elements).twice
  end

  it 'does not interpret an unreadable hint batch as evidence that links are absent' do
    fail_first_hint_read

    expect(session.has_no_css?('a', wait: 0.02)).to be false
    expect(browser).to have_received(:find_elements).at_least(:twice)
  end

  it 'can confirm absence only after querying the replacement document' do
    allow(browser).to receive(:find_elements).and_return(elements, [])
    allow(browser).to receive(:execute_script).and_raise(error)

    expect(session.has_no_css?('a')).to be true
    expect(browser).to have_received(:find_elements).twice
  end

  it 'requeries children of a scoped element after its hint read fails' do
    allow(elements.first).to receive(:find_elements).and_return(elements)
    container = session.find(:css, 'main', match: :first)
    fail_first_hint_read

    expect(container.has_css?('a', count: 3)).to be true
    expect(elements.first).to have_received(:find_elements).twice
  end

  [0, 0.02].each do |wait|
    it "raises instead of confirming absence when hints fail for the entire #{wait} second wait" do
      allow(browser).to receive(:execute_script).and_raise(error)

      expect { session.has_no_css?('a', wait: wait) }.to raise_error(Capybara::RetryableQueryError) { |raised|
        expect(raised.cause).to equal(error)
      }
    end
  end

  it 'raises when a positive query cannot read hints before its deadline' do
    allow(browser).to receive(:execute_script).and_raise(error)

    expect { session.has_css?('a', wait: 0.02) }.to raise_error(Capybara::RetryableQueryError)
  end

  it 'keeps the original cause and backtrace of the retryable query error' do
    allow(browser).to receive(:execute_script).and_raise(error)

    expect { driver.find_css('a', uses_visibility: true) }.to raise_error(Capybara::RetryableQueryError) { |raised|
      expect(raised.message).to include(error.message)
      expect(raised.cause).to equal(error)
      expect(raised.backtrace).to eq(error.backtrace)
    }
  end

  [{ styles: { color: 'red' } }, { position: true }].each do |hints|
    it "preserves query recovery for #{hints.keys.first} hint reads" do
      allow(browser).to receive(:execute_script).and_raise(error)

      expect { driver.find_css('a', **hints) }.to raise_error(Capybara::RetryableQueryError) { |raised|
        expect(raised.cause).to equal(error)
      }
    end
  end

  it 'preserves unrelated inspector errors without retrying the query' do
    other = Selenium::WebDriver::Error::UnknownError.new('browser disconnected')
    allow(browser).to receive(:execute_script).and_raise(other)

    expect { session.has_css?('a') }.to(raise_error { |raised| expect(raised).to equal(other) })
    expect(browser).to have_received(:find_elements).once
  end

  it 'preserves different exception classes with the same message' do
    other = Selenium::WebDriver::Error::JavascriptError.new(error.message)
    allow(browser).to receive(:execute_script).and_raise(other)

    expect { session.has_css?('a') }.to(raise_error { |raised| expect(raised).to equal(other) })
    expect(browser).to have_received(:find_elements).once
  end

  it 'does not change hint errors for a non-Chrome browser' do
    allow(browser).to receive(:browser).and_return(:firefox)
    allow(browser).to receive(:execute_script).and_raise(error)

    expect { session.has_css?('a') }.to(raise_error { |raised| expect(raised).to equal(error) })
    expect(browser).to have_received(:find_elements).once
  end

  it 'preserves explicit synchronization error lists' do
    allow(browser).to receive(:execute_script).and_raise(error)

    expect do
      session.document.synchronize(0.02, errors: []) { driver.find_css('a', uses_visibility: true) }
    end.to raise_error(Capybara::RetryableQueryError)
    expect(browser).to have_received(:find_elements).once
  end

  it 'keeps existing stale-element handling for hint reads' do
    allow(browser).to receive(:execute_script).and_raise(Selenium::WebDriver::Error::StaleElementReferenceError)

    expect(session.has_css?('a', count: 3)).to be true
  end

  it 'does not repeat a completed click when the following hint query retries' do
    elements.each { |element| allow(element).to receive(:click) }
    session.find(:css, 'a', match: :first).click
    fail_first_hint_read

    expect(session.has_css?('a', count: 3)).to be true
    expect(elements.first).to have_received(:click).once
  end

  it 'does not convert inspector errors from a click' do
    allow(elements.first).to receive(:click).and_raise(error)

    expect { session.find(:css, 'a', match: :first).click }.to(raise_error { |raised| expect(raised).to equal(error) })
    expect(elements.first).to have_received(:click).once
  end
end
