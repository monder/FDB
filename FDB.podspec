#
# Be sure to run `pod lib lint FDB.podspec' to ensure this is a
# valid spec and remove all comments before submitting the spec.
#
# Any lines starting with a # are optional, but encouraged
#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = "FDB"
  s.version          = "0.0.1"
  s.summary          = "An Objective-C wrapper around SQLite with object mapping"
  s.description      = <<-DESC
                       The FDB library provides easy object mapping to database entries and vice versa.
                       DESC
  s.homepage         = "https://github.com/monder/FDB"
  s.license          = 'MIT'
  s.author           = { "Aleksejs Sinicins" => "a.sinicins@me.com" }
  s.source           = { :git => "https://github.com/monder/FDB.git", :tag => s.version.to_s }

  s.platform     = :ios, '7.0'
  s.requires_arc = true
  s.library = 'sqlite3'
  s.source_files = 'Pod'
end
