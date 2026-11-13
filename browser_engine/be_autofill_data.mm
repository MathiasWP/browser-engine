#import "browser_engine/be_autofill_data.h"

#include <optional>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/uuid.h"
#import "browser_engine/be_passwords_data.h"
#import "browser_engine/be_window.h"
#include "chrome/browser/autofill/personal_data_manager_factory.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/grit/generated_resources.h"
#include "components/autofill/core/browser/country_type.h"
#include "components/autofill/core/browser/data_manager/personal_data_manager.h"
#include "components/autofill/core/browser/data_model/addresses/autofill_profile.h"
#include "components/autofill/core/browser/data_model/addresses/autofill_structured_address_component.h"
#include "components/autofill/core/browser/data_model/payments/credit_card.h"
#include "components/autofill/core/browser/field_types.h"
#include "components/autofill/core/browser/geo/autofill_country.h"
#include "components/autofill/core/browser/ui/addresses/autofill_address_util.h"
#include "components/autofill/core/browser/ui/country_combobox_model.h"
#include "components/autofill/core/common/autofill_prefs.h"
#include "components/autofill/core/common/credit_card_number_validation.h"
#include "components/device_reauth/device_reauth_metrics_util.h"
#include "components/strings/grit/components_strings.h"
#include "ui/base/l10n/l10n_util.h"

using autofill::AutofillProfile;
using autofill::CreditCard;

@interface BEChromiumAddress : NSObject <BEAddress>
- (instancetype)initWithIdentifier:(NSString*)identifier
                             label:(NSString*)label
                          sublabel:(NSString*)sublabel
                            fields:(NSDictionary<NSNumber*, NSString*>*)fields
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumAddress

@synthesize identifier = _identifier;
@synthesize label = _label;
@synthesize sublabel = _sublabel;
@synthesize fields = _fields;

- (instancetype)initWithIdentifier:(NSString*)identifier
                             label:(NSString*)label
                          sublabel:(NSString*)sublabel
                            fields:(NSDictionary<NSNumber*, NSString*>*)fields {
  if ((self = [super init])) {
    _identifier = [identifier copy];
    _label = [label copy];
    _sublabel = [sublabel copy];
    _fields = [fields copy];
  }
  return self;
}

@end

@interface BEChromiumAddressFormatField : NSObject <BEAddressFormatField>
- (instancetype)initWithField:(BEAddressField)field
                        label:(NSString*)label
                       isLong:(BOOL)isLong
                   isRequired:(BOOL)isRequired NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumAddressFormatField

@synthesize field = _field;
@synthesize label = _label;
@synthesize isLong = _isLong;
@synthesize isRequired = _isRequired;

- (instancetype)initWithField:(BEAddressField)field
                        label:(NSString*)label
                       isLong:(BOOL)isLong
                   isRequired:(BOOL)isRequired {
  if ((self = [super init])) {
    _field = field;
    _label = [label copy];
    _isLong = isLong;
    _isRequired = isRequired;
  }
  return self;
}

@end

@interface BEChromiumPaymentCard : NSObject <BEPaymentCard>
- (instancetype)initWithIdentifier:(NSString*)identifier
                           network:(NSString*)network
                 networkIdentifier:(NSString*)networkIdentifier
                    lastFourDigits:(NSString*)lastFourDigits
                        nameOnCard:(NSString*)nameOnCard
                          nickname:(NSString*)nickname
                   expirationMonth:(NSInteger)expirationMonth
                    expirationYear:(NSInteger)expirationYear
                         isExpired:(BOOL)isExpired
                   hasSecurityCode:(BOOL)hasSecurityCode
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumPaymentCard

@synthesize identifier = _identifier;
@synthesize network = _network;
@synthesize networkIdentifier = _networkIdentifier;
@synthesize lastFourDigits = _lastFourDigits;
@synthesize nameOnCard = _nameOnCard;
@synthesize nickname = _nickname;
@synthesize expirationMonth = _expirationMonth;
@synthesize expirationYear = _expirationYear;
@synthesize isExpired = _isExpired;
@synthesize hasSecurityCode = _hasSecurityCode;

- (instancetype)initWithIdentifier:(NSString*)identifier
                           network:(NSString*)network
                 networkIdentifier:(NSString*)networkIdentifier
                    lastFourDigits:(NSString*)lastFourDigits
                        nameOnCard:(NSString*)nameOnCard
                          nickname:(NSString*)nickname
                   expirationMonth:(NSInteger)expirationMonth
                    expirationYear:(NSInteger)expirationYear
                         isExpired:(BOOL)isExpired
                   hasSecurityCode:(BOOL)hasSecurityCode {
  if ((self = [super init])) {
    _identifier = [identifier copy];
    _network = [network copy];
    _networkIdentifier = [networkIdentifier copy];
    _lastFourDigits = [lastFourDigits copy];
    _nameOnCard = [nameOnCard copy];
    _nickname = [nickname copy];
    _expirationMonth = expirationMonth;
    _expirationYear = expirationYear;
    _isExpired = isExpired;
    _hasSecurityCode = hasSecurityCode;
  }
  return self;
}

@end

namespace browser_engine {

namespace {

// How long a success counts for the cards, as for Chrome's own card prompts
// (ChromeAutofillClient::GetDeviceAuthenticator()).
constexpr base::TimeDelta kCardAuthValidity = base::Seconds(60);

// Each part of an address the app knows, with the type Chrome stores it as:
// the types Chrome's address editor offers (autofillPrivate's AddressEntry).
struct AddressFieldType {
  BEAddressField field;
  autofill::FieldType type;
};

constexpr AddressFieldType kAddressFields[] = {
    {BEAddressFieldName, autofill::NAME_FULL},
    {BEAddressFieldOrganization, autofill::COMPANY_NAME},
    // Its lines separated by "\n".
    {BEAddressFieldStreet, autofill::ADDRESS_HOME_STREET_ADDRESS},
    {BEAddressFieldCity, autofill::ADDRESS_HOME_CITY},
    {BEAddressFieldState, autofill::ADDRESS_HOME_STATE},
    {BEAddressFieldPostalCode, autofill::ADDRESS_HOME_ZIP},
    {BEAddressFieldCountry, autofill::ADDRESS_HOME_COUNTRY},
    {BEAddressFieldPhone, autofill::PHONE_HOME_WHOLE_NUMBER},
    {BEAddressFieldEmail, autofill::EMAIL_ADDRESS},
    {BEAddressFieldDependentLocality,
     autofill::ADDRESS_HOME_DEPENDENT_LOCALITY},
    {BEAddressFieldSortingCode, autofill::ADDRESS_HOME_SORTING_CODE},
};

std::optional<BEAddressField> FieldFor(autofill::FieldType type) {
  for (const AddressFieldType& field : kAddressFields) {
    if (field.type == type) {
      return field.field;
    }
  }
  return std::nullopt;
}

const std::string& Locale() {
  return g_browser_process->GetApplicationLocale();
}

}  // namespace

BEAutofillData::BEAutofillData(Profile* profile,
                               base::RepeatingClosure addresses_changed,
                               base::RepeatingClosure cards_changed)
    : profile_(profile->GetOriginalProfile()),
      addresses_changed_(std::move(addresses_changed)),
      cards_changed_(std::move(cards_changed)),
      authentication_(std::make_unique<BEAuthentication>(
          profile_,
          device_reauth::DeviceAuthSource::kAutofill)) {
  // The profile's, as autofillPrivate's; it starts loading when made.
  if (autofill::PersonalDataManager* personal_data =
          autofill::PersonalDataManagerFactory::GetForBrowserContext(
              profile_)) {
    address_observation_.Observe(&personal_data->address_data_manager());
    payments_observation_.Observe(&personal_data->payments_data_manager());
  }
  // "Verify it's you" is a pref; Chrome's settings page watches it as one.
  pref_change_registrar_.Init(profile_->GetPrefs());
  pref_change_registrar_.Add(
      autofill::prefs::kAutofillPaymentMethodsMandatoryReauth, cards_changed_);
}

BEAutofillData::~BEAutofillData() = default;

void BEAutofillData::OnAddressDataChanged() {
  addresses_changed_.Run();
}

void BEAutofillData::OnPaymentsDataChanged() {
  cards_changed_.Run();
}

autofill::AddressDataManager* BEAutofillData::LoadedAddresses() {
  autofill::AddressDataManager* addresses = address_observation_.GetSource();
  return addresses && addresses->has_initial_load_finished() ? addresses
                                                             : nullptr;
}

autofill::PaymentsDataManager* BEAutofillData::LoadedPayments() {
  autofill::PaymentsDataManager* payments = payments_observation_.GetSource();
  return payments && payments->is_payments_data_loaded() ? payments : nullptr;
}

// MARK: Addresses

NSArray<id<BEAddress>>* BEAutofillData::Addresses() {
  autofill::AddressDataManager* addresses = LoadedAddresses();
  if (!addresses) {
    return @[];
  }
  // autofill_util::GenerateAddressList(), local addresses only. The pointers
  // last until the next database update: everything is copied out now.
  std::vector<const AutofillProfile*> profiles;
  for (const AutofillProfile* profile : addresses->GetProfilesForSettings()) {
    if (profile->record_type() ==
        AutofillProfile::RecordType::kLocalOrSyncable) {
      profiles.push_back(profile);
    }
  }
  // Labels telling the addresses apart ("Jane Doe, 1 Main St, Springfield"):
  // the part before the first separator, and the rest (ProfileToAddressEntry()
  // splits them so).
  const std::vector<std::u16string> labels =
      AutofillProfile::CreateDifferentiatingLabels(profiles, Locale());
  const std::u16string separator =
      l10n_util::GetStringUTF16(IDS_AUTOFILL_ADDRESS_SUMMARY_SEPARATOR);
  NSMutableArray<id<BEAddress>>* list = [NSMutableArray array];
  for (size_t i = 0; i < profiles.size() && i < labels.size(); ++i) {
    const std::u16string& summary = labels[i];
    const size_t split = summary.find(separator);
    std::u16string label;
    std::u16string sublabel;
    base::TrimWhitespace(summary.substr(0, split), base::TRIM_ALL, &label);
    if (split != std::u16string::npos) {
      base::TrimWhitespace(summary.substr(split + separator.size()),
                           base::TRIM_ALL, &sublabel);
    }
    NSMutableDictionary<NSNumber*, NSString*>* fields =
        [NSMutableDictionary dictionary];
    for (const AddressFieldType& field : kAddressFields) {
      const std::u16string value = profiles[i]->GetRawInfo(field.type);
      if (!value.empty()) {
        fields[@(field.field)] = base::SysUTF16ToNSString(value);
      }
    }
    [list addObject:[[BEChromiumAddress alloc]
                        initWithIdentifier:base::SysUTF8ToNSString(
                                               profiles[i]->guid())
                                     label:base::SysUTF16ToNSString(label)
                                  sublabel:base::SysUTF16ToNSString(sublabel)
                                    fields:fields]];
  }
  return list;
}

NSArray<NSArray<NSString*>*>* BEAutofillData::Countries() {
  if (countries_) {
    return countries_;
  }
  // autofill_util::GenerateCountryList(): the countries Chrome has address
  // formats for, by name in the app's language. The model puts the default
  // country first, then a separator, then them all: the app has the default
  // as DefaultCountry().
  autofill::CountryComboboxModel model;
  model.SetCountries(autofill::GeoIpCountryCode(std::string()), Locale());
  const autofill::CountryComboboxModel::CountryVector& countries =
      model.countries();
  size_t first = 0;
  for (size_t i = 0; i < countries.size(); ++i) {
    if (!countries[i]) {
      first = i + 1;
      break;
    }
  }
  NSMutableArray<NSArray<NSString*>*>* list = [NSMutableArray array];
  for (size_t i = first; i < countries.size(); ++i) {
    if (!countries[i]) {
      continue;
    }
    [list addObject:@[
      base::SysUTF8ToNSString(countries[i]->country_code()),
      base::SysUTF16ToNSString(countries[i]->name())
    ]];
    country_codes_.insert(countries[i]->country_code());
  }
  countries_ = list;
  return countries_;
}

NSString* BEAutofillData::DefaultCountry() {
  // What Chrome gives a new address: the variations service's country, or
  // the app's language's.
  if (autofill::AddressDataManager* addresses =
          address_observation_.GetSource()) {
    return base::SysUTF8ToNSString(
        addresses->GetDefaultCountryCodeForNewAddress().value());
  }
  return base::SysUTF8ToNSString(
      autofill::AutofillCountry::GetDefaultCountryCodeForNewAddress(
          autofill::GeoIpCountryCode(std::string()), Locale())
          .value());
}

std::string BEAutofillData::CountryCode(NSString* code) {
  Countries();
  const std::string country =
      base::ToUpperASCII(base::SysNSStringToUTF8(code ?: @""));
  return country_codes_.contains(country) ? country : std::string();
}

NSArray<NSArray<id<BEAddressFormatField>>*>* BEAutofillData::AddressFormat(
    NSString* code) {
  std::string country = CountryCode(code);
  if (country.empty()) {
    country = base::SysNSStringToUTF8(DefaultCountry());
  }
  // AutofillPrivateGetAddressComponentsFunction: libaddressinput's format
  // for the country (the US's for one it hasn't), with Chrome's extensions,
  // its labels in the app's language.
  std::vector<std::vector<autofill::AutofillAddressUIComponent>> lines;
  std::string language;
  autofill::GetAddressComponents(country, Locale(), /*include_literals=*/false,
                                 &lines, &language);
  NSMutableArray<NSArray<id<BEAddressFormatField>>*>* format =
      [NSMutableArray array];
  for (const std::vector<autofill::AutofillAddressUIComponent>& line : lines) {
    NSMutableArray<id<BEAddressFormatField>>* fields = [NSMutableArray array];
    for (const autofill::AutofillAddressUIComponent& component : line) {
      const std::optional<BEAddressField> field = FieldFor(component.field);
      if (!field) {
        continue;
      }
      [fields
          addObject:
              [[BEChromiumAddressFormatField alloc]
                  initWithField:*field
                          label:base::SysUTF8ToNSString(component.name)
                         isLong:component.length_hint ==
                                autofill::AutofillAddressUIComponent::HINT_LONG
                     isRequired:component.is_required]];
    }
    if (fields.count) {
      [format addObject:fields];
    }
  }
  // AddressEditDialog: phone and email aren't in the format, but go on a line
  // of their own after it, the email the longer.
  [format addObject:@[
    [[BEChromiumAddressFormatField alloc]
        initWithField:BEAddressFieldPhone
                label:base::SysUTF16ToNSString(l10n_util::GetStringUTF16(
                          IDS_SETTINGS_AUTOFILL_ADDRESSES_PHONE))
               isLong:NO
           isRequired:NO],
    [[BEChromiumAddressFormatField alloc]
        initWithField:BEAddressFieldEmail
                label:base::SysUTF16ToNSString(l10n_util::GetStringUTF16(
                          IDS_SETTINGS_AUTOFILL_ADDRESSES_EMAIL))
               isLong:YES
           isRequired:NO],
  ]];
  return format;
}

NSString* BEAutofillData::SaveAddress(
    NSString* identifier,
    NSDictionary<NSNumber*, NSString*>* fields) {
  autofill::AddressDataManager* addresses = LoadedAddresses();
  if (!addresses) {
    return nil;
  }
  // AutofillPrivateSaveAddressFunction: a copy of the address, or a new
  // local one.
  const AutofillProfile* existing = nullptr;
  if (identifier) {
    existing = addresses->GetProfileByGUID(base::SysNSStringToUTF8(identifier));
    if (!existing || existing->record_type() !=
                         AutofillProfile::RecordType::kLocalOrSyncable) {
      return nil;
    }
  }
  // The country given, or the one it had, or a new address's.
  std::string country = CountryCode(fields[@(BEAddressFieldCountry)]);
  if (country.empty() && existing) {
    country =
        base::UTF16ToUTF8(existing->GetRawInfo(autofill::ADDRESS_HOME_COUNTRY));
  }
  if (country.empty()) {
    country = addresses->GetDefaultCountryCodeForNewAddress().value();
  }
  AutofillProfile profile =
      existing ? *existing
               : AutofillProfile(AutofillProfile::RecordType::kLocalOrSyncable,
                                 autofill::AddressCountryCode(country));
  bool filled = false;
  for (const AddressFieldType& field : kAddressFields) {
    std::u16string value;
    if (field.field == BEAddressFieldCountry) {
      value = base::UTF8ToUTF16(country);
    } else {
      base::TrimWhitespace(
          base::SysNSStringToUTF16(fields[@(field.field)] ?: @""),
          base::TRIM_ALL, &value);
      filled |= !value.empty();
    }
    profile.SetRawInfoWithVerificationStatus(
        field.type, value, autofill::VerificationStatus::kUserVerified);
  }
  // Derives the name's and the street's parts from the whole, which filling
  // forms needs.
  profile.FinalizeAfterImport();
  // The language the address is written in, as the editor sets it from the
  // country's format.
  std::vector<std::vector<autofill::AutofillAddressUIComponent>> lines;
  std::string language;
  autofill::GetAddressComponents(country, Locale(), /*include_literals=*/false,
                                 &lines, &language);
  profile.set_language_code(language);

  if (existing) {
    addresses->UpdateProfile(profile);
    return [identifier copy];
  }
  // A new address of nothing but its country would fill nothing, though
  // Chrome's editor lets it through; and AddProfile() keeps nothing while
  // addresses are turned off, without saying so.
  if (!filled || !addresses->IsAutofillProfileEnabled()) {
    return nil;
  }
  addresses->AddProfile(profile);
  return base::SysUTF8ToNSString(profile.guid());
}

void BEAutofillData::RemoveAddress(NSString* identifier) {
  autofill::AddressDataManager* addresses = LoadedAddresses();
  const std::string guid = base::SysNSStringToUTF8(identifier);
  const AutofillProfile* profile =
      addresses ? addresses->GetProfileByGUID(guid) : nullptr;
  if (profile &&
      profile->record_type() == AutofillProfile::RecordType::kLocalOrSyncable) {
    addresses->RemoveProfile(guid);
  }
}

// MARK: Payment cards

const CreditCard* BEAutofillData::LocalCard(const std::string& guid) {
  autofill::PaymentsDataManager* payments = LoadedPayments();
  const CreditCard* card =
      payments ? payments->GetCreditCardByGUID(guid) : nullptr;
  return card && card->record_type() == CreditCard::RecordType::kLocalCard
             ? card
             : nullptr;
}

NSArray<id<BEPaymentCard>>* BEAutofillData::PaymentCards() {
  autofill::PaymentsDataManager* payments = LoadedPayments();
  if (!payments) {
    return @[];
  }
  // autofill_util::GenerateCreditCardList(), the cards on this Mac only,
  // masked to their last digits.
  NSMutableArray<id<BEPaymentCard>>* list = [NSMutableArray array];
  const base::Time now = base::Time::Now();
  for (const CreditCard* card : payments->GetLocalCreditCards()) {
    [list addObject:
              [[BEChromiumPaymentCard alloc]
                  initWithIdentifier:base::SysUTF8ToNSString(card->guid())
                             network:base::SysUTF16ToNSString(
                                         card->NetworkForDisplay())
                   networkIdentifier:base::SysUTF8ToNSString(card->network())
                      lastFourDigits:base::SysUTF16ToNSString(
                                         card->LastFourDigits())
                          nameOnCard:base::SysUTF16ToNSString(card->GetRawInfo(
                                         autofill::CREDIT_CARD_NAME_FULL))
                            nickname:base::SysUTF16ToNSString(card->nickname())
                     expirationMonth:card->expiration_month()
                      expirationYear:card->expiration_year()
                           isExpired:card->IsExpired(now)
                     hasSecurityCode:!card->cvc().empty()]];
  }
  return list;
}

bool BEAutofillData::CardsNeedAuthentication() {
  autofill::PaymentsDataManager* payments = payments_observation_.GetSource();
  return payments && payments->IsPaymentMethodsMandatoryReauthEnabled();
}

void BEAutofillData::RevealCard(NSString* identifier,
                                void (^completion)(NSString*, NSString*)) {
  const std::string guid = base::SysNSStringToUTF8(identifier);
  // AutofillPrivateGetLocalCardFunction: macOS asks only with "Verify it's
  // you" on. Either way, the answer comes on a later task.
  if (!LocalCard(guid) || !CardsNeedAuthentication()) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&BEAutofillData::OnRevealAuthenticated,
                                  weak_factory_.GetWeakPtr(), guid, completion,
                                  /*authenticated=*/true));
    return;
  }
  authentication_->Authenticate(
      kCardAuthValidity,
      l10n_util::GetStringUTF16(
          IDS_PAYMENTS_AUTOFILL_EDIT_CARD_MANDATORY_REAUTH_PROMPT),
      base::BindOnce(&BEAutofillData::OnRevealAuthenticated,
                     weak_factory_.GetWeakPtr(), guid, completion));
}

void BEAutofillData::OnRevealAuthenticated(const std::string& guid,
                                           void (^completion)(NSString*,
                                                              NSString*),
                                           bool authenticated) {
  // Looked up again: it may have changed or gone meanwhile.
  const CreditCard* card = authenticated ? LocalCard(guid) : nullptr;
  if (!card) {
    completion(nil, nil);
    return;
  }
  completion(base::SysUTF16ToNSString(card->number()),
             card->cvc().empty() ? nil : base::SysUTF16ToNSString(card->cvc()));
}

NSString* BEAutofillData::SaveCard(NSString* identifier,
                                   NSString* number,
                                   NSString* name,
                                   NSInteger month,
                                   NSInteger year,
                                   NSString* nickname,
                                   NSString* security_code) {
  autofill::PaymentsDataManager* payments = LoadedPayments();
  if (!payments) {
    return nil;
  }
  // What Chrome's card editor checks before it saves: a number passing the
  // Luhn check at its network's length (spaces and dashes as typed are
  // fine), a month, a four-digit year and a nickname without digits.
  const std::u16string digits = autofill::StripSeparatorsAndNormalizeDigits(
      base::SysNSStringToUTF16(number));
  std::u16string card_nickname;
  base::TrimWhitespace(base::SysNSStringToUTF16(nickname), base::TRIM_ALL,
                       &card_nickname);
  if (!autofill::IsValidCreditCardNumber(digits) || month < 1 || month > 12 ||
      year < 1000 || year > 9999 ||
      !CreditCard::IsNicknameValid(card_nickname)) {
    return nil;
  }
  // AutofillPrivateSaveCreditCardFunction: a copy of the card, or a new
  // local one the user has seen.
  const CreditCard* existing = nullptr;
  if (identifier) {
    existing = LocalCard(base::SysNSStringToUTF8(identifier));
    if (!existing) {
      return nil;
    }
  }
  CreditCard card =
      existing ? *existing
               : CreditCard(base::Uuid::GenerateRandomV4().AsLowercaseString());
  if (!existing) {
    card.set_is_user_confirmed(true);
  }
  std::u16string holder;
  base::TrimWhitespace(base::SysNSStringToUTF16(name), base::TRIM_ALL, &holder);
  card.SetRawInfo(autofill::CREDIT_CARD_NAME_FULL, holder);
  card.SetRawInfo(autofill::CREDIT_CARD_NUMBER, digits);
  card.SetExpirationMonth(static_cast<int>(month));
  card.SetExpirationYear(static_cast<int>(year));
  card.SetNickname(card_nickname);
  // The editor has a security code field only while Chrome may keep them;
  // otherwise what the card has stays.
  if (payments->IsPaymentCvcStorageEnabled()) {
    std::u16string cvc;
    base::TrimWhitespace(base::SysNSStringToUTF16(security_code),
                         base::TRIM_ALL, &cvc);
    card.set_cvc(cvc);
  }

  if (existing) {
    // Only a change is written.
    if (existing->Compare(card) != 0) {
      payments->UpdateCreditCard(card);
    }
    return [identifier copy];
  }
  // AddCreditCard() keeps no second copy of a card, and nothing while
  // payment methods are off, without saying so.
  for (const CreditCard* saved : payments->GetLocalCreditCards()) {
    if (saved->Compare(card) == 0) {
      return base::SysUTF8ToNSString(saved->guid());
    }
  }
  if (!payments->IsAutofillPaymentMethodsEnabled()) {
    return nil;
  }
  payments->AddCreditCard(card);
  return base::SysUTF8ToNSString(card.guid());
}

void BEAutofillData::RemoveCard(NSString* identifier) {
  const std::string guid = base::SysNSStringToUTF8(identifier);
  // RemoveByGUID() takes IBANs too: only a card goes.
  if (LocalCard(guid)) {
    LoadedPayments()->RemoveByGUID(guid);
  }
}

void BEAutofillData::RemoveAllSecurityCodes() {
  // AutofillPrivateBulkDeleteAllCvcsFunction, the local ones (servers' are
  // Google's). ClearLocalCvcs() CHECKs for the database.
  autofill::PaymentsDataManager* payments = LoadedPayments();
  if (payments && payments->GetLocalDatabase()) {
    payments->ClearLocalCvcs();
  }
}

void BEAutofillData::SetCardsNeedAuthentication(bool needed,
                                                void (^completion)(BOOL)) {
  autofill::PaymentsDataManager* payments = LoadedPayments();
  if (!payments ||
      payments->IsPaymentMethodsMandatoryReauthEnabled() == needed) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE,
        base::BindOnce(&BEAutofillData::OnNeedAuthenticationAuthenticated,
                       weak_factory_.GetWeakPtr(), needed, completion,
                       /*authenticated=*/false));
    return;
  }
  // AuthenticateUserAndFlipMandatoryAuthToggle: turning it on or off asks
  // first.
  authentication_->Authenticate(
      kCardAuthValidity,
      l10n_util::GetStringUTF16(IDS_PAYMENTS_AUTOFILL_MANDATORY_REAUTH_PROMPT),
      base::BindOnce(&BEAutofillData::OnNeedAuthenticationAuthenticated,
                     weak_factory_.GetWeakPtr(), needed, completion));
}

void BEAutofillData::OnNeedAuthenticationAuthenticated(bool needed,
                                                       void (^completion)(BOOL),
                                                       bool authenticated) {
  autofill::PaymentsDataManager* payments = payments_observation_.GetSource();
  if (!authenticated || !payments ||
      payments->IsPaymentMethodsMandatoryReauthEnabled() == needed) {
    completion(NO);
    return;
  }
  // The pref's change comes back as cards_changed_.
  payments->SetPaymentMethodsMandatoryReauthEnabled(needed);
  completion(YES);
}

}  // namespace browser_engine

// MARK: BEWindowAddresses

@implementation BEChromiumWindow (Autofill)

- (NSArray<id<BEAddress>>*)addresses {
  browser_engine::BEAutofillData* data = [self autofillData];
  return data ? data->Addresses() : @[];
}

- (NSArray<NSArray<NSString*>*>*)addressCountries {
  browser_engine::BEAutofillData* data = [self autofillData];
  return data ? data->Countries() : @[];
}

- (NSString*)defaultAddressCountry {
  browser_engine::BEAutofillData* data = [self autofillData];
  return data ? data->DefaultCountry() : @"";
}

- (NSArray<NSArray<id<BEAddressFormatField>>*>*)addressFormatForCountry:
    (NSString*)code {
  browser_engine::BEAutofillData* data = [self autofillData];
  return data ? data->AddressFormat(code) : @[];
}

- (NSString*)saveAddress:(NSString*)identifier
                  fields:(NSDictionary<NSNumber*, NSString*>*)fields {
  browser_engine::BEAutofillData* data = [self autofillData];
  return data ? data->SaveAddress(identifier, fields) : nil;
}

- (void)removeAddress:(NSString*)identifier {
  if (browser_engine::BEAutofillData* data = [self autofillData]) {
    data->RemoveAddress(identifier);
  }
}

// MARK: BEWindowPaymentCards

- (NSArray<id<BEPaymentCard>>*)paymentCards {
  browser_engine::BEAutofillData* data = [self autofillData];
  return data ? data->PaymentCards() : @[];
}

- (BOOL)paymentCardsNeedAuthentication {
  browser_engine::BEAutofillData* data = [self autofillData];
  return data && data->CardsNeedAuthentication();
}

- (void)revealPaymentCard:(NSString*)identifier
               completion:(void (^)(NSString* number,
                                    NSString* securityCode))completion {
  if (browser_engine::BEAutofillData* data = [self autofillData]) {
    data->RevealCard(identifier, completion);
  }
}

- (NSString*)savePaymentCard:(NSString*)identifier
                      number:(NSString*)number
                  nameOnCard:(NSString*)name
             expirationMonth:(NSInteger)month
              expirationYear:(NSInteger)year
                    nickname:(NSString*)nickname
                securityCode:(NSString*)securityCode {
  browser_engine::BEAutofillData* data = [self autofillData];
  return data ? data->SaveCard(identifier, number, name, month, year, nickname,
                               securityCode)
              : nil;
}

- (void)removePaymentCard:(NSString*)identifier {
  if (browser_engine::BEAutofillData* data = [self autofillData]) {
    data->RemoveCard(identifier);
  }
}

- (void)removeAllSecurityCodes {
  if (browser_engine::BEAutofillData* data = [self autofillData]) {
    data->RemoveAllSecurityCodes();
  }
}

- (void)setPaymentCardsNeedAuthentication:(BOOL)needed
                               completion:(void (^)(BOOL changed))completion {
  if (browser_engine::BEAutofillData* data = [self autofillData]) {
    data->SetCardsNeedAuthentication(needed, completion);
  }
}

@end
