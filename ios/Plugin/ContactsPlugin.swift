import Foundation
import Capacitor
import Contacts
import ContactsUI
import SwiftUI

enum CallingMethod {
    case GetContact
    case GetContacts
    case CreateContact
    case DeleteContact
    case PickContact
    case SelectLimitedContacts
}

@objc(ContactsPlugin)
public class ContactsPlugin: CAPPlugin, CNContactPickerDelegate {
    private let implementation = Contacts()

    private var callingMethod: CallingMethod?

    private var pickContactCallbackId: String?

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        let permissionState: String

        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            permissionState = "prompt"
        case .restricted, .denied:
            permissionState = "denied"
        case .authorized:
            permissionState = "granted"
        case .limited:
            permissionState = "limited"
        @unknown default:
            permissionState = "prompt"
        }

        call.resolve([
            "contacts": permissionState
        ])
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        CNContactStore().requestAccess(for: .contacts) { [weak self] _, _  in
            self?.checkPermissions(call)
        }
    }

    private func requestContactsPermission(_ call: CAPPluginCall, _ callingMethod: CallingMethod) {
        self.callingMethod = callingMethod
        if isContactsPermissionGranted() {
            permissionCallback(call)
        } else {
            CNContactStore().requestAccess(for: .contacts) { [weak self] _, _  in
                self?.permissionCallback(call)
            }
        }
    }

    private func isContactsPermissionGranted() -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined, .restricted, .denied:
            return false
        case .authorized, .limited:
            return true
        @unknown default:
            return false
        }
    }

    private func permissionCallback(_ call: CAPPluginCall) {
        let method = self.callingMethod

        self.callingMethod = nil

        if !isContactsPermissionGranted() {
            call.reject("Permission is required to access contacts.")
            return
        }

        switch method {
        case .GetContact:
            getContact(call)
        case .GetContacts:
            getContacts(call)
        case .CreateContact:
            createContact(call)
        case .DeleteContact:
            deleteContact(call)
        case .PickContact:
            pickContact(call)
        case .SelectLimitedContacts:
            selectLimitedContacts(call)
        default:
            // No method was being called,
            // so nothing has to be done here.
            break
        }
    }

    @objc func getContact(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.GetContact)
        } else {
            let contactId = call.getString("contactId")

            guard let contactId = contactId else {
                call.reject("Parameter `contactId` not provided.")
                return
            }

            let projectionInput = GetContactsProjectionInput(call.getObject("projection") ?? JSObject())

            let contact = implementation.getContact(contactId, projectionInput)

            guard let contact = contact else {
                call.reject("Contact not found.")
                return
            }

            call.resolve([
                "contact": contact.getJSObject()
            ])
        }
    }

    @objc func getContacts(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.GetContacts)
        } else {
            let projectionInput = GetContactsProjectionInput(call.getObject("projection") ?? JSObject())

            let contacts = implementation.getContacts(projectionInput)

            var contactsJSArray: JSArray = JSArray()

            for contact in contacts {
                contactsJSArray.append(contact.getJSObject())
            }

            call.resolve([
                "contacts": contactsJSArray
            ])
        }
    }

    @objc func createContact(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.CreateContact)
        } else {
            let contactInput = CreateContactInput.init(call.getObject("contact", JSObject()))

            let contactId = implementation.createContact(contactInput)

            guard let contactId = contactId else {
                call.reject("Something went wrong.")
                return
            }

            call.resolve([
                "contactId": contactId
            ])
        }
    }

    @objc func deleteContact(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.DeleteContact)
        } else {
            let contactId = call.getString("contactId")

            guard let contactId = contactId else {
                call.reject("Parameter `contactId` not provided.")
                return
            }

            if !implementation.deleteContact(contactId) {
                call.reject("Something went wrong.")
                return
            }

            call.resolve()
        }
    }

    @objc func pickContact(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.PickContact)
        } else {
            DispatchQueue.main.async {
                // Save the call and its callback id
                self.bridge?.saveCall(call)
                self.pickContactCallbackId = call.callbackId

                // Initialize the contact picker
                let contactPicker = CNContactPickerViewController()
                // Mark current class as the delegate class,
                // this will make the callback `contactPicker` actually work.
                contactPicker.delegate = self
                // Present (open) the native contact picker.
                self.bridge?.viewController?.present(contactPicker, animated: true)
            }
        }
    }

    public func contactPicker(_ picker: CNContactPickerViewController, didSelect selectedContact: CNContact) {
        let call = self.bridge?.savedCall(withID: self.pickContactCallbackId ?? "")

        guard let call = call else {
            return
        }

        let contact = ContactPayload(selectedContact.identifier)

        contact.fillData(selectedContact)

        call.resolve([
            "contact": contact.getJSObject()
        ])

        self.bridge?.releaseCall(call)
    }

    @objc func selectLimitedContacts(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.SelectLimitedContacts)
        } else {
            guard #available(iOS 18.0, *) else {
                call.reject("Requires iOS 18 or newer for limited contacts picker.")
                return
            }

            DispatchQueue.main.async {
                var hostingController: UIHostingController<ContactAccessPickerHostingView>! = nil

                let pickerView = ContactAccessPickerHostingView { identifiers in
                    let store = CNContactStore()
                    let keys: [CNKeyDescriptor] = [
                        CNContactGivenNameKey as CNKeyDescriptor,
                        CNContactFamilyNameKey as CNKeyDescriptor,
                        CNContactPhoneNumbersKey as CNKeyDescriptor
                    ]

                    var result: [[String: Any]] = []

                    for id in identifiers {
                        do {
                            let contact = try store.unifiedContact(withIdentifier: id, keysToFetch: keys)
                            result.append([
                                "identifier": contact.identifier,
                                "givenName": contact.givenName,
                                "familyName": contact.familyName,
                                "phoneNumbers": contact.phoneNumbers.map { $0.value.stringValue }
                            ])
                        } catch {
                            print("Failed to fetch contact with id \(id): \(error)")
                        }
                    }

                    call.resolve(["contacts": result])

                    DispatchQueue.main.async {
                        hostingController.dismiss(animated: true)
                    }
                }

                hostingController = UIHostingController(rootView: pickerView)
                hostingController.modalPresentationStyle = .fullScreen
                self.bridge?.viewController?.present(hostingController, animated: true)
            }
        }
    }
}

// SwiftUI view for contact access picker
@available(iOS 18.0, *)
struct ContactAccessPickerHostingView: View {
    @State private var isPresented = true
    var completion: ([String]) -> Void

    var body: some View {
        EmptyView()
            .contactAccessPicker(isPresented: $isPresented) { identifiers in
                completion(identifiers)
            }
            .onChange(of: isPresented) { newValue in
                if !newValue {
                        completion([])
                }
            }
    }
}