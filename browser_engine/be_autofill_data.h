// The addresses and payment cards Chrome fills forms with, for the app's own
// settings pages (BEWindowAddresses, BEWindowPaymentCards), for one window's
// profile (its everyday profile for a private window): Chrome's
// PersonalDataManager as its settings pages use it (autofillPrivate), without
// a tab. Local addresses and cards only: account addresses and Google
// Payments' cards need Google.

#ifndef BROWSER_ENGINE_BE_AUTOFILL_DATA_H_
#define BROWSER_ENGINE_BE_AUTOFILL_DATA_H_

#import <Foundation/Foundation.h>

#include <memory>
#include <set>
#include <string>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#import "browser_engine/public/BEEngineOptional.h"
#include "components/autofill/core/browser/data_manager/addresses/address_data_manager.h"
#include "components/autofill/core/browser/data_manager/payments/payments_data_manager.h"
#include "components/prefs/pref_change_registrar.h"

class Profile;

namespace autofill {
class CreditCard;
}  // namespace autofill

namespace browser_engine {

class BEAuthentication;

// One per window, made when the app first asks, destroyed with the window
// (before its profile). Completions still to come then never run.
//
// Chrome loads the data when the profile's PersonalDataManager is made;
// until then the lists are empty and saving does nothing. Writes go to the
// web database, and come back a moment later as the closures.
class BEAutofillData : public autofill::AddressDataManager::Observer,
                       public autofill::PaymentsDataManager::Observer {
 public:
  // `addresses_changed` and `cards_changed` run when those change, from
  // whoever; `cards_changed` also when "Verify it's you" is turned on or off.
  BEAutofillData(Profile* profile,
                 base::RepeatingClosure addresses_changed,
                 base::RepeatingClosure cards_changed);
  BEAutofillData(const BEAutofillData&) = delete;
  BEAutofillData& operator=(const BEAutofillData&) = delete;
  ~BEAutofillData() override;

  // Addresses.
  NSArray<id<BEAddress>>* Addresses();
  NSArray<NSArray<NSString*>*>* Countries();
  NSString* DefaultCountry();
  // The country's own fields, then phone and email, as Chrome's address
  // editor lays them out under its country menu (the country itself isn't
  // among them). Fields Chrome has but BEAddressField hasn't (a few
  // countries' landmarks, admin levels and the like) are left out.
  NSArray<NSArray<id<BEAddressFormatField>>*>* AddressFormat(NSString* code);
  // `fields` are the whole address: a field not given is emptied. Nil before
  // the addresses have loaded, for an address that isn't a local one, and for
  // a new one of nothing but its country or while addresses are turned off.
  NSString* SaveAddress(NSString* identifier,
                        NSDictionary<NSNumber*, NSString*>* fields);
  void RemoveAddress(NSString* identifier);

  // Payment cards.
  NSArray<id<BEPaymentCard>>* PaymentCards();
  bool CardsNeedAuthentication();
  void RevealCard(NSString* identifier,
                  void (^completion)(NSString* number,
                                     NSString* security_code));
  // Nil also before the cards have loaded, for a card that isn't a local one,
  // and for a new one while payment methods are turned off. A card saved
  // already, field for field, is that card.
  NSString* SaveCard(NSString* identifier,
                     NSString* number,
                     NSString* name,
                     NSInteger month,
                     NSInteger year,
                     NSString* nickname,
                     NSString* security_code);
  void RemoveCard(NSString* identifier);
  void RemoveAllSecurityCodes();
  void SetCardsNeedAuthentication(bool needed, void (^completion)(BOOL));

 private:
  // autofill::AddressDataManager::Observer:
  void OnAddressDataChanged() override;
  // autofill::PaymentsDataManager::Observer:
  void OnPaymentsDataChanged() override;

  // The managers, loaded; null while they aren't (or the profile has none).
  autofill::AddressDataManager* LoadedAddresses();
  autofill::PaymentsDataManager* LoadedPayments();
  // A local card, or null.
  const autofill::CreditCard* LocalCard(const std::string& guid);
  // `code` as an ISO code of Countries(), or the empty string.
  std::string CountryCode(NSString* code);

  void OnRevealAuthenticated(const std::string& guid,
                             void (^completion)(NSString*, NSString*),
                             bool authenticated);
  void OnNeedAuthenticationAuthenticated(bool needed,
                                         void (^completion)(BOOL),
                                         bool authenticated);

  const raw_ptr<Profile> profile_;
  base::RepeatingClosure addresses_changed_;
  base::RepeatingClosure cards_changed_;
  base::ScopedObservation<autofill::AddressDataManager,
                          autofill::AddressDataManager::Observer>
      address_observation_{this};
  base::ScopedObservation<autofill::PaymentsDataManager,
                          autofill::PaymentsDataManager::Observer>
      payments_observation_{this};
  PrefChangeRegistrar pref_change_registrar_;
  std::unique_ptr<BEAuthentication> authentication_;
  // The countries, made once: they don't change while Chrome runs.
  NSArray<NSArray<NSString*>*>* __strong countries_ = nil;
  std::set<std::string> country_codes_;
  base::WeakPtrFactory<BEAutofillData> weak_factory_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_AUTOFILL_DATA_H_
