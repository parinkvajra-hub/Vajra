# Backend Gaps and Changes Required — `lockapp-server`

The following gaps/issues were identified in the `lockapp-server` backend codebase when comparing its REST API endpoints against the client requests made by the `shopkeeper` React Native application.

---

## 1. Missing Forgot Password and Reset Password Endpoints
* **Issue**: The shopkeeper application implements a password recovery wizard that makes calls to `/api/auth/shopkeeper/forgot-password` (to send an OTP) and `/api/auth/shopkeeper/reset-password` (to reset the password using the OTP). However, these endpoints are completely missing from the backend `routes/auth.js` controller.
* **Impact**: Tapping "Forgot Password" or attempting to recover a password in the app will always result in a `404 Not Found` API error.
  * Implement a secure `POST /shopkeeper/forgot-password` in `routes/auth.js` that checks for a rate-limit (e.g. 1 min), generates a random 6-digit OTP, hashes it using SHA256 before saving to the DB with a 10-minute expiration, and sends it to the shopkeeper's registered email address.
  * Implement `POST /shopkeeper/reset-password` in `routes/auth.js` to verify the OTP, update and bcrypt-hash the new password, and invalidate the OTP properties immediately upon successful reset (making it single-use).

---

## 2. Missing Password Change Endpoint
* **Issue**: The shopkeeper profile screen allows changing the account password, which sends a `PUT` request to `/api/profile/password`. This endpoint does not exist in `routes/profile.js`.
* **Impact**: Changing the password from the settings screen fails immediately with a `404 Not Found` API error.
* **Suggested Fix**:
  * Add a `PUT /password` route to `routes/profile.js` protected by shopkeeper auth.
  * The route should:
    1. Accept `currentPassword` and `newPassword` in the request body.
    2. Retrieve the shopkeeper and compare `currentPassword` against `shopkeeper.password` using `bcrypt.compare`.
    3. If correct, hash `newPassword` and update the database.

---

## 3. Shopkeeper Info Serialization Discrepancy (`profilePic` vs `profilePicUrl`)
* **Issue**: The shopkeeper database schema uses `profilePicUrl` to store the avatar image. 
  * The `Shopkeeper` schema's `toJSON` method successfully maps `profilePicUrl` to `profilePic` for serialization:
    ```javascript
    shopkeeperSchema.methods.toJSON = function () {
      const obj = this.toObject();
      delete obj.password;
      obj.profilePic = obj.profilePicUrl || '';
      return obj;
    };
    ```
  * However, the registration (`POST /api/auth/shopkeeper/register`) and login (`POST /api/auth/shopkeeper/login`) routes bypass the `toJSON` method by using `.toObject()` manually before sending the response:
    ```javascript
    const shopkeeperObj = shopkeeper.toObject();
    delete shopkeeperObj.password;
    ```
* **Impact**: When logging in or registering, the response payload contains `profilePicUrl` instead of `profilePic`. Because the React Native frontend expects `shopkeeper.profilePic` to render the avatar on the dashboard and profile header, the avatar remains blank/broken until the user pulls to refresh (which hits GET `/api/profile`, triggering the correct serialization).
* **Suggested Fix**:
  * In `routes/auth.js` (for both register and login endpoints), change:
    ```javascript
    const shopkeeperObj = shopkeeper.toObject();
    ```
    to:
    ```javascript
    const shopkeeperObj = shopkeeper.toJSON();
    ```
    This ensures proper field mapping and password removal are handled uniformly using Mongoose's built-in schema serialization.
