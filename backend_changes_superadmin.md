# Proposed Backend Changes for lockapp-server

This document outlines the changes required in the backend (`lockapp-server` repository) to support the Super Admin application features, resolve data schema mismatches, and fix critical production bugs.

---

## 1. Authorize Admins to Send Device Commands

### Problem
The device command endpoints in `lockapp-server/routes/commands.js` are currently restricted exclusively to the `shopkeeper` role using the `authorizeShopkeeper` middleware:
```javascript
// Current routes in lockapp-server/routes/commands.js
router.post('/:deviceId/send', authorizeShopkeeper, ...);
router.post('/:deviceId/offline', authorizeShopkeeper, ...);
```
Since Super Admins and Support Admins also need to lock/unlock/manage devices from their portal, they receive `403 Forbidden` errors when attempting to execute commands.

### Solution
Replace `authorizeShopkeeper` with a role-based authorization helper that allows both `shopkeeper` and administrative roles (`super_admin`, `support_admin`) to invoke these endpoints.

#### Middleware Change (`lockapp-server/middleware/auth.js`)
If it doesn't already exist, add a generic role authorization middleware:
```javascript
const authorizeRoles = (...allowedRoles) => {
  return (req, res, next) => {
    if (!req.user || !allowedRoles.includes(req.user.role)) {
      return res.status(403).json({
        success: false,
        message: 'Access Denied: Insufficient permissions.',
      });
    }
    next();
  };
};
```

#### Routes Change (`lockapp-server/routes/commands.js`)
Update the routes to permit admin roles:
```javascript
// Updated routes in lockapp-server/routes/commands.js
router.post('/:deviceId/send', authorizeRoles('shopkeeper', 'super_admin', 'support_admin'), ...);
router.post('/:deviceId/offline', authorizeRoles('shopkeeper', 'super_admin', 'support_admin'), ...);
```

---

## 2. Fix Ticket Creation CastError (Mongoose)

### Problem
In `lockapp-server/models/Ticket.js`, the `deviceId` field is defined as an `ObjectId` referencing the `Device` model:
```javascript
deviceId: { type: mongoose.Schema.Types.ObjectId, ref: 'Device' }
```
However, in `lockapp-server/routes/commands.js` (lines 329-335), when a command fails and the system automatically logs a ticket, it passes the hardware UUID string (`commandLog.deviceId`) directly into the `deviceId` field:
```javascript
await Ticket.create({
  ticketId,
  shopkeeperId: commandLog.shopkeeperId,
  deviceId: commandLog.deviceId, // ❌ This is a UUID string!
  customerName: device ? device.customerName : 'Unknown',
  commandLogId: commandLog._id,
  ...
});
```
Mongoose attempts to cast the string (e.g. `dev-lzn3a12d`) to an `ObjectId`. Since a custom device UUID is not a valid 24-character hex string, Mongoose throws a `CastError: Cast to ObjectId failed...` and aborts ticket creation. No tickets are generated for failed commands.

### Solution
Resolve the Device document first, and save the actual MongoDB `_id` (ObjectId) of the device.

#### Code Modification (`lockapp-server/routes/commands.js`)
Update ticket creation inside the command failure listener:
```javascript
// Find device info for ticket
const device = await Device.findOne({ deviceId: commandLog.deviceId });

await Ticket.create({
  ticketId,
  shopkeeperId: commandLog.shopkeeperId,
  deviceId: device ? device._id : null, // ✅ Save the ObjectId instead of the UUID string
  customerName: device ? device.customerName : 'Unknown',
  commandLogId: commandLog._id,
  commandAttempted: commandLog.commandType,
  commandLabel: commandLog.commandLabel,
  errorReason: errorReason || 'Command failed',
  status: 'open',
  priority: 'medium',
});
```

---

## 3. Implement Missing System Configuration & Upload Routes

### Problem
The Super Admin dashboard allows administrators to upload custom Wallpaper templates and update the QR codes (Payment QR & Device Owner setup QR).
However:
1. The `SystemConfig` model schema is missing the `deviceOwnerQrUrl` property.
2. The endpoint `PUT /api/config/device-owner-qr` is not implemented.
3. The endpoint `POST /api/config/upload` (to upload base64 images) is not implemented, resulting in `404 Not Found` when trying to save images.

### Solution

#### Model Update (`lockapp-server/models/SystemConfig.js`)
Add the `deviceOwnerQrUrl` field to the schema:
```javascript
const systemConfigSchema = new mongoose.Schema(
  {
    ...
    paymentQrUrl: { type: String, default: '' },
    deviceOwnerQrUrl: { type: String, default: '' }, // ✅ Added field
    upiId: { type: String, default: '' },
    ...
  }
);
```

#### Add Route: Update Device Owner QR (`lockapp-server/routes/config.js`)
Add the handler to update the Device Owner setup QR:
```javascript
// ─── PUT /device-owner-qr — Update device owner QR URL (admin only) ───
router.put('/device-owner-qr', async (req, res) => {
  try {
    const { deviceOwnerQrUrl } = req.body;

    if (!deviceOwnerQrUrl) {
      return res.status(400).json({
        success: false,
        message: 'deviceOwnerQrUrl is required.',
        data: {},
      });
    }

    const config = await Config.findOneAndUpdate(
      { configKey: 'platform' },
      {
        $set: {
          deviceOwnerQrUrl,
          updatedBy: req.user.id,
        },
      },
      { new: true, upsert: true }
    );

    return res.status(200).json({
      success: true,
      message: 'Device Owner QR URL updated successfully.',
      data: { deviceOwnerQrUrl: config.deviceOwnerQrUrl },
    });
  } catch (error) {
    console.error('Update Device Owner QR error:', error.message);
    return res.status(500).json({
      success: false,
      message: 'Server error updating device owner QR URL.',
      data: {},
    });
  }
});
```

#### Add Route: Image Upload Gateway (`lockapp-server/routes/config.js`)
Implement `POST /upload` using a service like Cloudinary or local storage. Below is a sample implementation using Cloudinary:
```javascript
const cloudinary = require('cloudinary').v2;

// Configure Cloudinary in index.js/app.js:
// cloudinary.config({
//   cloud_name: process.env.CLOUDINARY_NAME,
//   api_key: process.env.CLOUDINARY_API_KEY,
//   api_secret: process.env.CLOUDINARY_API_SECRET
// });

// ─── POST /upload — Upload base64 image (admin only) ───────────────────
router.post('/upload', async (req, res) => {
  try {
    const { image } = req.body; // base64 string

    if (!image) {
      return res.status(400).json({
        success: false,
        message: 'Base64 image string is required.',
      });
    }

    // Upload to Cloudinary
    const uploadResponse = await cloudinary.uploader.upload(image, {
      folder: 'lockapp_uploads',
    });

    return res.status(200).json({
      success: true,
      message: 'Image uploaded successfully.',
      data: {
        url: uploadResponse.secure_url,
      },
    });
  } catch (error) {
    console.error('Image upload error:', error.message);
    return res.status(500).json({
      success: false,
      message: 'Server error uploading image.',
    });
  }
});
```

---

## 4. Fix Shopkeeper `.lean()` Serialization Discrepancy

### Problem
In the shopkeeper listing route (`GET /api/shopkeepers`), the query uses `.lean()` to improve performance:
```javascript
const shopkeepers = await Shopkeeper.find({ isDeleted: false }).lean();
```
Calling `.lean()` tells Mongoose to skip creating virtual fields. In the `Shopkeeper` schema, `profilePic` is a virtual field mapped from the database-stored `profilePicUrl`:
```javascript
shopkeeperSchema.virtual('profilePic').get(function () {
  return this.profilePicUrl || '...default_avatar...';
});
```
Because of `.lean()`, the virtual `profilePic` is omitted from the JSON payload. This causes broken avatar images in the React Native Super Admin app.

### Solution
Either remove `.lean()` from the query, or map the property in the route handler, or use the client-side fallback we implemented (`item.profilePic || item.profilePicUrl`). Removal of `.lean()` is recommended if virtuals are critical:
```javascript
// lockapp-server/controllers/shopkeepers.js / routes
const shopkeepers = await Shopkeeper.find({ isDeleted: false }); // Avoid .lean() to preserve virtuals
```
